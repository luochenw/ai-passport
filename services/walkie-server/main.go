package main

import (
	"context"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/sideshow/apns2"
	"github.com/sideshow/apns2/token"
)

const (
	audioProtocolVersion = 1
	audioHeaderSize      = 12
	audioMaxFrameSize    = 92
	audioFlagEnd         = 0x02

	clientQueueDepth = 300
	preRollFrames    = 250
	floorTimeout     = 5 * time.Second
)

type controlMessage struct {
	Type      string `json:"type"`
	Room      string `json:"room,omitempty"`
	Name      string `json:"name,omitempty"`
	ClientID  string `json:"clientId,omitempty"`
	Token     string `json:"token,omitempty"`
	PushToken string `json:"pushToken,omitempty"`
	Stream    uint16 `json:"stream,omitempty"`
}

type serverEvent struct {
	Type     string `json:"type"`
	ClientID string `json:"clientId,omitempty"`
	Room     string `json:"room,omitempty"`
	Members  int    `json:"members,omitempty"`
	// ⚠ speaker 事件必须同时带 ClientID。客户端要靠它判断「在讲话的是不是
	// 我自己」—— 只发 name 的话,两个昵称相同的客户端(默认昵称就都是
	// "Passport")会把对方的声音当成自己的回声丢掉,表现为屏幕显示有人在
	// 讲话、却一个字也听不到。
	Speaker string `json:"speaker,omitempty"`
	Stream  uint16 `json:"stream,omitempty"`
	Message string `json:"message,omitempty"`
}

type outbound struct {
	kind websocket.MessageType
	data []byte
}

type client struct {
	conn    *websocket.Conn
	control chan outbound
	audio   chan outbound
	room    *room

	id        string
	name      string
	pushToken string
}

type room struct {
	name            string
	clients         map[*client]struct{}
	speaker         *client
	stream          uint16
	lastActivity    time.Time
	preRoll         [][]byte
	replaySpeaker   string
	replaySpeakerID string
	replayStream    uint16
	replayFrames    [][]byte
	replayUntil     time.Time
}

type pushRegistration struct {
	Room  string `json:"room"`
	Name  string `json:"name"`
	Token string `json:"token"`
}

type pushSender interface {
	send(ctx context.Context, deviceToken, speaker, room string, stream uint16) error
}

type noopPushSender struct{}

func (noopPushSender) send(context.Context, string, string, string, uint16) error {
	return nil
}

type apnsPushSender struct {
	client *apns2.Client
	topic  string
}

func (s *apnsPushSender) send(ctx context.Context, deviceToken, speaker, room string, stream uint16) error {
	notification := &apns2.Notification{
		DeviceToken: deviceToken,
		Topic:       s.topic,
		PushType:    apns2.PushTypePushToTalk,
		Priority:    apns2.PriorityHigh,
		// Apple requires expiration 0 for PTT. apns2 omits the header for the
		// Unix epoch itself, so use one second before it: Unix() is exactly 0
		// while After(time.Unix(0, 0)) remains true and the header is emitted.
		Expiration: time.Unix(0, 1),
		Payload: map[string]any{
			"activeSpeaker": speaker,
			"room":          room,
			"stream":        stream,
		},
	}
	response, err := s.client.PushWithContext(ctx, notification)
	if err != nil {
		return err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("APNs status %d: %s", response.StatusCode, response.Reason)
	}
	return nil
}

type walkieServer struct {
	mu            sync.Mutex
	rooms         map[string]*room
	registrations map[string]pushRegistration
	sharedToken   string
	push          pushSender
	statePath     string
}

func newWalkieServer(sharedToken string, push pushSender) *walkieServer {
	return newWalkieServerWithState(sharedToken, push, "")
}

func newWalkieServerWithState(sharedToken string, push pushSender, statePath string) *walkieServer {
	if push == nil {
		push = noopPushSender{}
	}
	s := &walkieServer{
		rooms:         make(map[string]*room),
		registrations: make(map[string]pushRegistration),
		sharedToken:   sharedToken,
		push:          push,
		statePath:     statePath,
	}
	s.loadRegistrations()
	go s.sweepFloors()
	return s
}

func (s *walkieServer) handleHealth(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"ok":true}`))
}

func (s *walkieServer) handleWebSocket(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		log.Printf("websocket accept: %v", err)
		return
	}
	c := &client{
		conn:    conn,
		control: make(chan outbound, 32),
		audio:   make(chan outbound, clientQueueDepth),
	}
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	defer s.removeClient(c)
	defer conn.CloseNow()

	go c.writeLoop(ctx)
	if err := s.readLoop(ctx, c); err != nil &&
		!errors.Is(err, context.Canceled) &&
		websocket.CloseStatus(err) == -1 {
		log.Printf("client read: %v", err)
	}
}

func (c *client) writeLoop(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case msg := <-c.control:
			if !c.write(ctx, msg) {
				return
			}
			continue
		default:
		}
		select {
		case <-ctx.Done():
			return
		case msg := <-c.control:
			if !c.write(ctx, msg) {
				return
			}
		case msg := <-c.audio:
			if !c.write(ctx, msg) {
				return
			}
		}
	}
}

func (c *client) write(ctx context.Context, msg outbound) bool {
	writeCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	err := c.conn.Write(writeCtx, msg.kind, msg.data)
	cancel()
	if err == nil {
		return true
	}
	_ = c.conn.Close(websocket.StatusInternalError, "write failed")
	return false
}

func (s *walkieServer) readLoop(ctx context.Context, c *client) error {
	for {
		kind, data, err := c.conn.Read(ctx)
		if err != nil {
			return err
		}
		switch kind {
		case websocket.MessageText:
			if err := s.handleControl(c, data); err != nil {
				s.sendEvent(c, serverEvent{Type: "error", Message: err.Error()})
			}
		case websocket.MessageBinary:
			s.handleAudio(c, data)
		}
	}
}

func (s *walkieServer) handleControl(c *client, data []byte) error {
	var message controlMessage
	if err := json.Unmarshal(data, &message); err != nil {
		return errors.New("invalid control message")
	}

	if c.room == nil {
		if message.Type != "join" {
			return errors.New("join is required first")
		}
		return s.join(c, message)
	}

	switch message.Type {
	case "ping":
		s.sendEvent(c, serverEvent{Type: "pong"})
	case "push_token":
		s.updatePushToken(c, message.PushToken)
	case "ptt_request":
		s.requestFloor(c, message.Stream)
	case "ptt_release":
		s.releaseFloor(c, message.Stream)
	default:
		return errors.New("unknown control message")
	}
	return nil
}

func (s *walkieServer) join(c *client, message controlMessage) error {
	roomName := cleanField(message.Room, 48)
	name := cleanField(message.Name, 48)
	clientID := cleanField(message.ClientID, 96)
	if roomName == "" || name == "" || clientID == "" {
		return errors.New("room, name, and clientId are required")
	}
	if s.sharedToken != "" && message.Token != s.sharedToken {
		return errors.New("unauthorized")
	}

	s.mu.Lock()
	r := s.rooms[roomName]
	if r == nil {
		r = &room{name: roomName, clients: make(map[*client]struct{})}
		s.rooms[roomName] = r
	}
	var replaced []*client
	floorReleased := false
	for existing := range r.clients {
		if existing.id != clientID {
			continue
		}
		delete(r.clients, existing)
		replaced = append(replaced, existing)
		if r.speaker == existing {
			s.clearFloorLocked(r)
			floorReleased = true
		}
	}
	c.room = r
	c.id = clientID
	c.name = name
	c.pushToken = cleanHexToken(message.PushToken)
	r.clients[c] = struct{}{}
	if c.pushToken != "" {
		s.registrations[clientID] = pushRegistration{
			Room: roomName, Name: name, Token: c.pushToken,
		}
	} else if registration, ok := s.registrations[clientID]; ok {
		registration.Room = roomName
		registration.Name = name
		s.registrations[clientID] = registration
	}
	s.saveRegistrationsLocked()
	memberCount := len(r.clients)
	speaker := r.speaker
	stream := r.stream
	preRoll := cloneFrames(r.preRoll)
	replaySpeaker := r.replaySpeaker
	replaySpeakerID := r.replaySpeakerID
	replayStream := r.replayStream
	replayFrames := cloneFrames(r.replayFrames)
	replayAvailable := speaker == nil && replaySpeaker != "" &&
		replaySpeakerID != clientID && time.Now().Before(r.replayUntil)
	clients := snapshotClients(r, nil)
	s.mu.Unlock()

	for _, old := range replaced {
		_ = old.conn.Close(websocket.StatusNormalClosure, "replaced by restored connection")
	}
	if floorReleased {
		s.broadcastEvent(clients, serverEvent{Type: "idle"})
	}
	s.sendEvent(c, serverEvent{
		Type: "welcome", ClientID: clientID, Room: roomName, Members: memberCount,
	})
	s.broadcastEvent(clients, serverEvent{Type: "members", Members: memberCount})
	if speaker != nil {
		s.sendRealtimeEvent(c, serverEvent{
			Type: "speaker", ClientID: speaker.id, Speaker: speaker.name, Stream: stream})
		for _, frame := range preRoll {
			s.sendBinary(c, frame)
		}
	} else if replayAvailable {
		s.sendRealtimeEvent(c, serverEvent{
			Type: "speaker", ClientID: replaySpeakerID, Speaker: replaySpeaker, Stream: replayStream,
		})
		for _, frame := range replayFrames {
			s.sendBinary(c, frame)
		}
		s.sendRealtimeEvent(c, serverEvent{Type: "idle"})
	}
	log.Printf("joined room=%q client=%q members=%d", roomName, name, memberCount)
	return nil
}

func (s *walkieServer) updatePushToken(c *client, raw string) {
	token := cleanHexToken(raw)
	s.mu.Lock()
	c.pushToken = token
	key := c.id
	if token == "" {
		delete(s.registrations, key)
	} else {
		s.registrations[key] = pushRegistration{
			Room: c.room.name, Name: c.name, Token: token,
		}
	}
	s.saveRegistrationsLocked()
	s.mu.Unlock()
}

func (s *walkieServer) requestFloor(c *client, stream uint16) {
	s.mu.Lock()
	r := c.room
	if r.speaker != nil && r.speaker != c {
		speakerName := r.speaker.name
		s.mu.Unlock()
		s.sendEvent(c, serverEvent{Type: "floor_denied", Speaker: speakerName})
		return
	}
	r.speaker = c
	r.stream = stream
	r.lastActivity = time.Now()
	r.preRoll = nil
	r.replaySpeaker = ""
	r.replaySpeakerID = ""
	r.replayStream = 0
	r.replayFrames = nil
	r.replayUntil = time.Time{}
	clients := snapshotClients(r, nil)
	pushTokens := make([]string, 0, len(s.registrations))
	for key, registration := range s.registrations {
		if registration.Room == r.name && key != c.id {
			pushTokens = append(pushTokens, registration.Token)
		}
	}
	s.mu.Unlock()

	s.sendEvent(c, serverEvent{Type: "floor_granted", Stream: stream})
	for _, peer := range clients {
		s.sendRealtimeEvent(peer, serverEvent{
			Type: "speaker", ClientID: c.id, Speaker: c.name, Stream: stream})
	}
	for _, deviceToken := range pushTokens {
		go func(token string) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := s.push.send(ctx, token, c.name, r.name, stream); err != nil {
				log.Printf("PTT push room=%q speaker=%q: %v", r.name, c.name, err)
			}
		}(deviceToken)
	}
}

func (s *walkieServer) releaseFloor(c *client, stream uint16) {
	s.mu.Lock()
	r := c.room
	if r == nil || r.speaker != c || (stream != 0 && stream != r.stream) {
		s.mu.Unlock()
		return
	}
	clients := s.clearFloorLocked(r)
	s.mu.Unlock()
	s.broadcastEvent(clients, serverEvent{Type: "idle"})
}

func (s *walkieServer) handleAudio(c *client, data []byte) {
	if len(data) < audioHeaderSize || len(data) > audioMaxFrameSize ||
		data[0] != audioProtocolVersion {
		return
	}
	samples := int(binary.LittleEndian.Uint16(data[6:8]))
	expectedPayload := 0
	if samples > 0 {
		expectedPayload = samples / 2
	}
	if samples > 160 || len(data) != audioHeaderSize+expectedPayload {
		return
	}
	stream := binary.LittleEndian.Uint16(data[2:4])

	s.mu.Lock()
	r := c.room
	if r == nil || r.speaker != c || r.stream != stream {
		s.mu.Unlock()
		return
	}
	r.lastActivity = time.Now()
	frame := append([]byte(nil), data...)
	r.preRoll = append(r.preRoll, frame)
	if len(r.preRoll) > preRollFrames {
		r.preRoll = r.preRoll[len(r.preRoll)-preRollFrames:]
	}
	recipients := snapshotClients(r, c)
	end := data[1]&audioFlagEnd != 0
	var idleClients []*client
	if end {
		r.replaySpeaker = c.name
		r.replaySpeakerID = c.id
		r.replayStream = r.stream
		r.replayFrames = cloneFrames(r.preRoll)
		r.replayUntil = time.Now().Add(10 * time.Second)
		idleClients = s.clearFloorLocked(r)
	}
	s.mu.Unlock()

	for _, peer := range recipients {
		s.sendBinary(peer, frame)
	}
	if end {
		for _, peer := range idleClients {
			s.sendRealtimeEvent(peer, serverEvent{Type: "idle"})
		}
	}
}

func (s *walkieServer) removeClient(c *client) {
	s.mu.Lock()
	r := c.room
	if r == nil {
		s.mu.Unlock()
		return
	}
	delete(r.clients, c)
	memberCount := len(r.clients)
	clients := snapshotClients(r, nil)
	released := r.speaker == c
	if released {
		s.clearFloorLocked(r)
	}
	if memberCount == 0 {
		delete(s.rooms, r.name)
	}
	s.mu.Unlock()

	if released {
		s.broadcastEvent(clients, serverEvent{Type: "idle"})
	}
	s.broadcastEvent(clients, serverEvent{Type: "members", Members: memberCount})
	log.Printf("left room=%q client=%q members=%d", r.name, c.name, memberCount)
}

func (s *walkieServer) clearFloorLocked(r *room) []*client {
	r.speaker = nil
	r.stream = 0
	r.lastActivity = time.Time{}
	r.preRoll = nil
	return snapshotClients(r, nil)
}

func (s *walkieServer) sweepFloors() {
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for now := range ticker.C {
		var broadcasts [][]*client
		s.mu.Lock()
		for _, r := range s.rooms {
			if r.speaker != nil && now.Sub(r.lastActivity) > floorTimeout {
				broadcasts = append(broadcasts, s.clearFloorLocked(r))
			}
		}
		s.mu.Unlock()
		for _, clients := range broadcasts {
			s.broadcastEvent(clients, serverEvent{Type: "idle"})
		}
	}
}

func (s *walkieServer) sendEvent(c *client, event serverEvent) {
	data, err := json.Marshal(event)
	if err == nil {
		select {
		case c.control <- outbound{kind: websocket.MessageText, data: data}:
		default:
			_ = c.conn.Close(websocket.StatusPolicyViolation, "control queue full")
		}
	}
}

func (s *walkieServer) broadcastEvent(clients []*client, event serverEvent) {
	for _, c := range clients {
		s.sendEvent(c, event)
	}
}

func (s *walkieServer) sendBinary(c *client, frame []byte) {
	message := outbound{kind: websocket.MessageBinary, data: append([]byte(nil), frame...)}
	c.sendRealtime(message)
}

func (s *walkieServer) sendRealtimeEvent(c *client, event serverEvent) {
	if event.Type == "speaker" {
		// The speaker event activates iOS Push to Talk receive mode. It must
		// not be discarded with stale audio when a slow client fills its
		// realtime queue. The control queue is prioritized by writeLoop.
		s.sendEvent(c, event)
		return
	}
	data, err := json.Marshal(event)
	if err == nil {
		c.sendRealtime(outbound{kind: websocket.MessageText, data: data})
	}
}

func (c *client) sendRealtime(message outbound) {
	select {
	case c.audio <- message:
	default:
		// Realtime audio is stale as soon as a receiver falls behind. Dropping
		// the oldest queued item is preferable to increasing latency or
		// blocking the active speaker.
		select {
		case <-c.audio:
		default:
		}
		select {
		case c.audio <- message:
		default:
		}
	}
}

func snapshotClients(r *room, except *client) []*client {
	out := make([]*client, 0, len(r.clients))
	for c := range r.clients {
		if c != except {
			out = append(out, c)
		}
	}
	return out
}

func cloneFrames(in [][]byte) [][]byte {
	out := make([][]byte, 0, len(in))
	for _, frame := range in {
		out = append(out, append([]byte(nil), frame...))
	}
	return out
}

func (s *walkieServer) loadRegistrations() {
	if s.statePath == "" {
		return
	}
	data, err := os.ReadFile(s.statePath)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			log.Printf("read state: %v", err)
		}
		return
	}
	var registrations map[string]pushRegistration
	if err := json.Unmarshal(data, &registrations); err != nil {
		log.Printf("decode state: %v", err)
		return
	}
	for id, registration := range registrations {
		registration.Token = cleanHexToken(registration.Token)
		if registration.Room != "" && registration.Token != "" {
			s.registrations[id] = registration
		}
	}
}

// Must be called while s.mu is held.
func (s *walkieServer) saveRegistrationsLocked() {
	if s.statePath == "" {
		return
	}
	data, err := json.MarshalIndent(s.registrations, "", "  ")
	if err != nil {
		log.Printf("encode state: %v", err)
		return
	}
	if err := os.MkdirAll(filepath.Dir(s.statePath), 0700); err != nil {
		log.Printf("create state directory: %v", err)
		return
	}
	tmp := s.statePath + ".tmp"
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		log.Printf("write state: %v", err)
		return
	}
	if err := os.Rename(tmp, s.statePath); err != nil {
		log.Printf("replace state: %v", err)
	}
}

func cleanField(value string, max int) string {
	value = strings.TrimSpace(value)
	value = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, value)
	runes := []rune(value)
	if len(runes) > max {
		value = string(runes[:max])
	}
	return value
}

func cleanHexToken(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	if value == "" {
		return ""
	}
	if _, err := hex.DecodeString(value); err != nil {
		return ""
	}
	return value
}

func defaultStatePath() string {
	dir, err := os.UserConfigDir()
	if err != nil || dir == "" {
		return ""
	}
	return filepath.Join(dir, "folotoy", "walkie-server.json")
}

func newPushSenderFromEnvironment() (pushSender, error) {
	keyPath := os.Getenv("WALKIE_APNS_KEY_PATH")
	keyID := os.Getenv("WALKIE_APNS_KEY_ID")
	teamID := os.Getenv("WALKIE_APNS_TEAM_ID")
	bundleID := os.Getenv("WALKIE_APNS_BUNDLE_ID")
	if keyPath == "" && keyID == "" && teamID == "" && bundleID == "" {
		return noopPushSender{}, nil
	}
	if keyPath == "" || keyID == "" || teamID == "" || bundleID == "" {
		return nil, errors.New("all WALKIE_APNS_* variables are required when APNs is enabled")
	}
	authKey, err := token.AuthKeyFromFile(keyPath)
	if err != nil {
		return nil, fmt.Errorf("load APNs key: %w", err)
	}
	client := apns2.NewTokenClient(&token.Token{
		AuthKey: authKey,
		KeyID:   keyID,
		TeamID:  teamID,
	})
	if os.Getenv("WALKIE_APNS_PRODUCTION") == "1" {
		client = client.Production()
	} else {
		client = client.Development()
	}
	return &apnsPushSender{
		client: client,
		topic:  bundleID + ".voip-ptt",
	}, nil
}

func main() {
	listen := flag.String("listen", "0.0.0.0:8787", "HTTP listen address")
	statePath := flag.String("state", defaultStatePath(), "path for persisted PTT push tokens")
	flag.Parse()

	push, err := newPushSenderFromEnvironment()
	if err != nil {
		log.Fatal(err)
	}
	server := newWalkieServerWithState(os.Getenv("WALKIE_SHARED_TOKEN"), push, *statePath)

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", server.handleHealth)
	mux.HandleFunc("/v1/ws", server.handleWebSocket)

	httpServer := &http.Server{
		Addr:              *listen,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("walkie server listening on %s", *listen)
	log.Fatal(httpServer.ListenAndServe())
}
