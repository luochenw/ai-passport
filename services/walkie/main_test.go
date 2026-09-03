package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/sideshow/apns2"
)

type captureRoundTripper struct {
	request *http.Request
	body    []byte
}

func (c *captureRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	c.request = request.Clone(request.Context())
	c.body, _ = io.ReadAll(request.Body)
	return &http.Response{
		StatusCode: http.StatusOK,
		Header:     make(http.Header),
		Body:       io.NopCloser(strings.NewReader(`{"reason":""}`)),
		Request:    request,
	}, nil
}

func dialTestClient(t *testing.T, url, id, name string) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, strings.Replace(url, "http://", "ws://", 1)+"/v1/ws", nil)
	if err != nil {
		t.Fatal(err)
	}
	join, _ := json.Marshal(controlMessage{
		Type: "join", Room: "test", Name: name, ClientID: id,
	})
	if err := conn.Write(ctx, websocket.MessageText, join); err != nil {
		t.Fatal(err)
	}
	return conn
}

func readEvent(t *testing.T, conn *websocket.Conn, wanted string) serverEvent {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	for {
		kind, data, err := conn.Read(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if kind != websocket.MessageText {
			continue
		}
		var event serverEvent
		if err := json.Unmarshal(data, &event); err != nil {
			t.Fatal(err)
		}
		if event.Type == wanted {
			return event
		}
	}
}

func writeControl(t *testing.T, conn *websocket.Conn, message controlMessage) {
	t.Helper()
	data, _ := json.Marshal(message)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatal(err)
	}
}

func TestRoomFloorAndAudioRelay(t *testing.T) {
	server := newWalkieServer("", nil)
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/ws", server.handleWebSocket)
	httpServer := httptest.NewServer(mux)
	defer httpServer.Close()

	alice := dialTestClient(t, httpServer.URL, "alice", "Alice")
	defer alice.CloseNow()
	bob := dialTestClient(t, httpServer.URL, "bob", "Bob")
	defer bob.CloseNow()

	readEvent(t, alice, "welcome")
	readEvent(t, bob, "welcome")

	writeControl(t, alice, controlMessage{Type: "ptt_request", Stream: 7})
	granted := readEvent(t, alice, "floor_granted")
	if granted.Stream != 7 {
		t.Fatalf("unexpected stream: %d", granted.Stream)
	}
	speaker := readEvent(t, bob, "speaker")
	if speaker.Speaker != "Alice" {
		t.Fatalf("unexpected speaker: %q", speaker.Speaker)
	}

	frame := make([]byte, audioHeaderSize)
	frame[0] = audioProtocolVersion
	binary.LittleEndian.PutUint16(frame[2:4], 7)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := alice.Write(ctx, websocket.MessageBinary, frame); err != nil {
		t.Fatal(err)
	}
	kind, received, err := bob.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if kind != websocket.MessageBinary || string(received) != string(frame) {
		t.Fatalf("audio frame mismatch: kind=%v len=%d", kind, len(received))
	}

	writeControl(t, bob, controlMessage{Type: "ptt_request", Stream: 9})
	denied := readEvent(t, bob, "floor_denied")
	if denied.Speaker != "Alice" {
		t.Fatalf("unexpected busy speaker: %q", denied.Speaker)
	}

	writeControl(t, alice, controlMessage{Type: "ptt_release", Stream: 7})
	readEvent(t, bob, "idle")
}

func TestSharedToken(t *testing.T) {
	server := newWalkieServer("secret", nil)
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/ws", server.handleWebSocket)
	httpServer := httptest.NewServer(mux)
	defer httpServer.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, strings.Replace(httpServer.URL, "http://", "ws://", 1)+"/v1/ws", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	writeControl(t, conn, controlMessage{
		Type: "join", Room: "test", Name: "Alice", ClientID: "alice", Token: "wrong",
	})
	event := readEvent(t, conn, "error")
	if event.Message != "unauthorized" {
		t.Fatalf("unexpected error: %q", event.Message)
	}
}

func TestCompletedTransmissionCanReplayAfterWake(t *testing.T) {
	server := newWalkieServer("", nil)
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/ws", server.handleWebSocket)
	httpServer := httptest.NewServer(mux)
	defer httpServer.Close()

	alice := dialTestClient(t, httpServer.URL, "alice", "Alice")
	defer alice.CloseNow()
	readEvent(t, alice, "welcome")
	writeControl(t, alice, controlMessage{Type: "ptt_request", Stream: 12})
	readEvent(t, alice, "floor_granted")

	frame := make([]byte, audioHeaderSize)
	frame[0] = audioProtocolVersion
	frame[1] = audioFlagEnd
	binary.LittleEndian.PutUint16(frame[2:4], 12)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := alice.Write(ctx, websocket.MessageBinary, frame); err != nil {
		t.Fatal(err)
	}

	bob := dialTestClient(t, httpServer.URL, "bob", "Bob")
	defer bob.CloseNow()
	readEvent(t, bob, "welcome")
	speaker := readEvent(t, bob, "speaker")
	if speaker.Speaker != "Alice" || speaker.Stream != 12 {
		t.Fatalf("unexpected replay speaker: %+v", speaker)
	}
	for {
		kind, received, err := bob.Read(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if kind != websocket.MessageBinary {
			continue
		}
		if string(received) != string(frame) {
			t.Fatal("replayed audio frame mismatch")
		}
		break
	}
	readEvent(t, bob, "idle")
}

func TestAPNsPushToTalkRequest(t *testing.T) {
	transport := &captureRoundTripper{}
	sender := &apnsPushSender{
		client: &apns2.Client{
			HTTPClient: &http.Client{Transport: transport},
			Host:       "https://api.push.apple.com",
		},
		topic: "com.example.walkie.voip-ptt",
	}
	if err := sender.send(context.Background(), strings.Repeat("ab", 32),
		"Alice", "test", 12); err != nil {
		t.Fatal(err)
	}
	if got := transport.request.Header.Get("apns-push-type"); got != "pushtotalk" {
		t.Fatalf("unexpected push type: %q", got)
	}
	if got := transport.request.Header.Get("apns-topic"); got != sender.topic {
		t.Fatalf("unexpected topic: %q", got)
	}
	if got := transport.request.Header.Get("apns-priority"); got != "10" {
		t.Fatalf("unexpected priority: %q", got)
	}
	if got := transport.request.Header.Get("apns-expiration"); got != "0" {
		t.Fatalf("unexpected expiration: %q", got)
	}
	var payload map[string]any
	if err := json.Unmarshal(transport.body, &payload); err != nil {
		t.Fatal(err)
	}
	if payload["activeSpeaker"] != "Alice" || payload["room"] != "test" {
		t.Fatalf("unexpected payload: %#v", payload)
	}
}

func TestSpeakerEventUsesReliableControlQueue(t *testing.T) {
	server := newWalkieServer("", nil)
	client := &client{
		control: make(chan outbound, 1),
		audio:   make(chan outbound, 1),
	}
	client.audio <- outbound{kind: websocket.MessageBinary, data: []byte{1}}

	server.sendRealtimeEvent(client, serverEvent{Type: "speaker", Speaker: "Alice"})

	select {
	case message := <-client.control:
		var event serverEvent
		if err := json.Unmarshal(message.data, &event); err != nil {
			t.Fatal(err)
		}
		if event.Type != "speaker" || event.Speaker != "Alice" {
			t.Fatalf("unexpected event: %+v", event)
		}
	default:
		t.Fatal("speaker event was not queued reliably")
	}
}
