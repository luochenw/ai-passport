package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

const (
	mealHistoryLimit = 52
	mealClientQueue  = 16
)

// 这个服务只认哪一栋楼的菜单。
//
// ⚠ 不要在这里写死具体的楼名。这是个开源仓库,写死等于把部署者在哪儿上班
// 一起公开了 —— 而且对别人也没用,他们的食堂不叫这个名字。
// 由部署时的 MEAL_BUILDING 决定;不设就不校验,菜单文件里写什么就是什么。
func mealBuildingName() string { return os.Getenv("MEAL_BUILDING") }

var mealFloorPattern = regexp.MustCompile(`(?i)(\d{1,2})\s*(?:层|f)`)

type mealOutlet struct {
	Floor  string   `json:"floor"`
	Name   string   `json:"name"`
	Dishes []string `json:"dishes,omitempty"`
}

type mealPeriod struct {
	Outlets          []mealOutlet `json:"outlets"`
	RecommendedFloor string       `json:"recommendedFloor"`
	Recommendation   string       `json:"recommendation"`
}

type mealDay struct {
	Date    string     `json:"date"`
	Weekday string     `json:"weekday,omitempty"`
	Lunch   mealPeriod `json:"lunch"`
	Dinner  mealPeriod `json:"dinner"`
}

type mealWeek struct {
	WeekOf   string    `json:"weekOf"`
	Building string    `json:"building"`
	Source   string    `json:"source,omitempty"`
	Updated  string    `json:"updatedAt"`
	Days     []mealDay `json:"days"`
}

type mealReminder struct {
	Date    string `json:"date"`
	Meal    string `json:"meal"`
	Floor   string `json:"floor"`
	Summary string `json:"summary,omitempty"`
	Message string `json:"message"`
}

type mealStateFile struct {
	Version int               `json:"version"`
	Weeks   []mealWeek        `json:"weeks"`
	Sent    map[string]string `json:"sent,omitempty"`
}

type mealClientMessage struct {
	Type      string `json:"type"`
	ClientID  string `json:"clientId,omitempty"`
	Installed bool   `json:"installed,omitempty"`
}

type mealServerEvent struct {
	Type     string        `json:"type"`
	Weeks    []mealWeek    `json:"weeks,omitempty"`
	Reminder *mealReminder `json:"reminder,omitempty"`
	Message  string        `json:"message,omitempty"`
}

type mealSubscriber struct {
	conn      *websocket.Conn
	control   chan []byte
	id        string
	installed bool
}

type mealHub struct {
	mu        sync.Mutex
	clients   map[*mealSubscriber]struct{}
	weeks     []mealWeek
	sent      map[string]string
	statePath string
	location  *time.Location
	now       func() time.Time
}

func newMealHub(statePath string) *mealHub {
	location, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		location = time.FixedZone("Asia/Shanghai", 8*60*60)
	}
	h := &mealHub{
		clients:   make(map[*mealSubscriber]struct{}),
		sent:      make(map[string]string),
		statePath: statePath,
		location:  location,
		now:       time.Now,
	}
	h.load()
	go h.runScheduler()
	return h
}

func (h *mealHub) handleWebSocket(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		log.Printf("meal websocket accept: %v", err)
		return
	}
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	defer conn.CloseNow()

	joinCtx, joinCancel := context.WithTimeout(ctx, 10*time.Second)
	kind, data, err := conn.Read(joinCtx)
	joinCancel()
	if err != nil || kind != websocket.MessageText {
		_ = conn.Close(websocket.StatusPolicyViolation, "meal join required")
		return
	}
	var message mealClientMessage
	if json.Unmarshal(data, &message) != nil || message.Type != "join" {
		_ = conn.Close(websocket.StatusPolicyViolation, "meal join required")
		return
	}
	clientID := cleanField(message.ClientID, 96)
	if clientID == "" {
		_ = conn.Close(websocket.StatusPolicyViolation, "clientId is required")
		return
	}

	client := &mealSubscriber{
		conn:      conn,
		control:   make(chan []byte, mealClientQueue),
		id:        clientID,
		installed: message.Installed,
	}
	go client.writeLoop(ctx)
	h.addClient(client)
	defer h.removeClient(client)
	h.sendSnapshot(client)

	for {
		kind, data, err := conn.Read(ctx)
		if err != nil {
			return
		}
		if kind != websocket.MessageText || json.Unmarshal(data, &message) != nil {
			continue
		}
		switch message.Type {
		case "subscribe":
			h.setInstalled(client, message.Installed)
			h.sendSnapshot(client)
		case "ping":
			h.send(client, mealServerEvent{Type: "pong"})
		}
	}
}

func (c *mealSubscriber) writeLoop(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case data := <-c.control:
			writeCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
			err := c.conn.Write(writeCtx, websocket.MessageText, data)
			cancel()
			if err != nil {
				_ = c.conn.Close(websocket.StatusInternalError, "meal write failed")
				return
			}
		}
	}
}

func (h *mealHub) addClient(client *mealSubscriber) {
	var replaced []*mealSubscriber
	h.mu.Lock()
	for existing := range h.clients {
		if existing.id == client.id {
			delete(h.clients, existing)
			replaced = append(replaced, existing)
		}
	}
	h.clients[client] = struct{}{}
	h.mu.Unlock()
	for _, existing := range replaced {
		_ = existing.conn.Close(websocket.StatusNormalClosure, "replaced connection")
	}
}

func (h *mealHub) removeClient(client *mealSubscriber) {
	h.mu.Lock()
	delete(h.clients, client)
	h.mu.Unlock()
}

func (h *mealHub) setInstalled(client *mealSubscriber, installed bool) {
	h.mu.Lock()
	if _, ok := h.clients[client]; ok {
		client.installed = installed
	}
	h.mu.Unlock()
}

func (h *mealHub) send(client *mealSubscriber, event mealServerEvent) {
	data, err := json.Marshal(event)
	if err != nil {
		return
	}
	select {
	case client.control <- data:
	default:
		_ = client.conn.Close(websocket.StatusPolicyViolation, "meal control queue full")
	}
}

func (h *mealHub) sendSnapshot(client *mealSubscriber) {
	h.mu.Lock()
	if !client.installed {
		h.mu.Unlock()
		return
	}
	weeks := cloneMealWeeks(h.weeks, 12)
	h.mu.Unlock()
	h.send(client, mealServerEvent{Type: "meal_state", Weeks: weeks})
}

func (h *mealHub) handleCurrent(w http.ResponseWriter, _ *http.Request) {
	h.mu.Lock()
	weeks := cloneMealWeeks(h.weeks, 1)
	h.mu.Unlock()
	writeJSON(w, http.StatusOK, mealServerEvent{Type: "meal_state", Weeks: weeks})
}

func (h *mealHub) handleWeeks(w http.ResponseWriter, r *http.Request) {
	limit := 12
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if value, err := strconv.Atoi(raw); err == nil {
			limit = max(1, min(value, mealHistoryLimit))
		}
	}
	h.mu.Lock()
	weeks := cloneMealWeeks(h.weeks, limit)
	h.mu.Unlock()
	writeJSON(w, http.StatusOK, mealServerEvent{Type: "meal_state", Weeks: weeks})
}

func (h *mealHub) handleUpdate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !requestIsLoopback(r) {
		http.Error(w, "meal updates are local-only", http.StatusForbidden)
		return
	}
	defer r.Body.Close()
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2<<20))
	var week mealWeek
	if err := decoder.Decode(&week); err != nil {
		http.Error(w, "invalid meal menu: "+err.Error(), http.StatusBadRequest)
		return
	}
	if err := normalizeMealWeek(&week, h.location, h.now()); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	h.mu.Lock()
	replaced := false
	for index := range h.weeks {
		if h.weeks[index].WeekOf == week.WeekOf {
			h.weeks[index] = mergeMealWeek(h.weeks[index], week)
			replaced = true
			break
		}
	}
	if !replaced {
		h.weeks = append(h.weeks, week)
	}
	sort.Slice(h.weeks, func(i, j int) bool { return h.weeks[i].WeekOf > h.weeks[j].WeekOf })
	if len(h.weeks) > mealHistoryLimit {
		h.weeks = h.weeks[:mealHistoryLimit]
	}
	h.saveLocked()
	clients := h.installedClientsLocked()
	weeks := cloneMealWeeks(h.weeks, 12)
	h.mu.Unlock()

	event := mealServerEvent{Type: "meal_state", Weeks: weeks}
	for _, client := range clients {
		h.send(client, event)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":      true,
		"weekOf":  week.WeekOf,
		"days":    len(week.Days),
		"clients": len(clients),
	})
}

func mergeMealWeek(existing, update mealWeek) mealWeek {
	days := make(map[string]mealDay, len(existing.Days)+len(update.Days))
	for _, day := range existing.Days {
		days[day.Date] = day
	}
	for _, day := range update.Days {
		days[day.Date] = day
	}
	update.Days = update.Days[:0]
	for _, day := range days {
		update.Days = append(update.Days, day)
	}
	sort.Slice(update.Days, func(i, j int) bool { return update.Days[i].Date < update.Days[j].Date })
	return update
}

func (h *mealHub) handleRemind(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !requestIsLoopback(r) {
		http.Error(w, "meal reminders are local-only", http.StatusForbidden)
		return
	}
	meal := r.URL.Query().Get("meal")
	if meal != "lunch" && meal != "dinner" {
		http.Error(w, "meal must be lunch or dinner", http.StatusBadRequest)
		return
	}
	reminder, count, ok := h.broadcastReminder(h.now(), meal, true)
	if !ok {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "sent": false})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":          true,
		"sent":        true,
		"subscribers": count,
		"reminder":    reminder,
	})
}

func (h *mealHub) runScheduler() {
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()
	for now := range ticker.C {
		h.runScheduledReminder(now)
	}
}

func (h *mealHub) runScheduledReminder(now time.Time) {
	local := now.In(h.location)
	if local.Weekday() < time.Monday || local.Weekday() > time.Friday {
		return
	}
	var meal string
	switch {
	case local.Hour() == 12 && local.Minute() >= 10 && local.Minute() < 15:
		meal = "lunch"
	case local.Hour() == 18 && local.Minute() >= 10 && local.Minute() < 15:
		meal = "dinner"
	default:
		return
	}
	h.broadcastReminder(local, meal, true)
}

func (h *mealHub) broadcastReminder(now time.Time, meal string, deduplicate bool) (mealReminder, int, bool) {
	local := now.In(h.location)
	key := local.Format("2006-01-02") + "/" + meal

	h.mu.Lock()
	reminder, ok := h.reminderLocked(local, meal)
	if !ok {
		h.mu.Unlock()
		return mealReminder{}, 0, false
	}
	clients := h.installedClientsLocked()
	if deduplicate {
		pending := clients[:0]
		for _, client := range clients {
			clientKey := client.id + "/" + key
			if _, sent := h.sent[clientKey]; sent {
				continue
			}
			h.sent[clientKey] = local.Format(time.RFC3339)
			pending = append(pending, client)
		}
		clients = pending
		h.pruneSentLocked(local.AddDate(0, 0, -35))
		h.saveLocked()
	}
	if len(clients) == 0 {
		h.mu.Unlock()
		return reminder, 0, false
	}
	h.mu.Unlock()

	event := mealServerEvent{Type: "meal_reminder", Reminder: &reminder}
	for _, client := range clients {
		h.send(client, event)
	}
	log.Printf("meal reminder date=%s meal=%s floor=%q subscribers=%d",
		reminder.Date, meal, reminder.Floor, len(clients))
	return reminder, len(clients), true
}

func (h *mealHub) reminderLocked(now time.Time, meal string) (mealReminder, bool) {
	date := now.Format("2006-01-02")
	for _, week := range h.weeks {
		for _, day := range week.Days {
			if day.Date != date {
				continue
			}
			period := day.Lunch
			label := "午饭"
			if meal == "dinner" {
				period = day.Dinner
				label = "晚饭"
			}
			if period.RecommendedFloor == "" {
				return mealReminder{}, false
			}
			message := label + "去" + period.RecommendedFloor
			if period.Recommendation != "" {
				message += "：" + period.Recommendation
			}
			return mealReminder{
				Date: date, Meal: meal, Floor: period.RecommendedFloor,
				Summary: period.Recommendation, Message: message,
			}, true
		}
	}
	return mealReminder{}, false
}

func (h *mealHub) installedClientsLocked() []*mealSubscriber {
	clients := make([]*mealSubscriber, 0, len(h.clients))
	for client := range h.clients {
		if client.installed {
			clients = append(clients, client)
		}
	}
	return clients
}

func normalizeMealWeek(week *mealWeek, location *time.Location, now time.Time) error {
	week.Building = cleanField(week.Building, 96)
	if want := mealBuildingName(); want != "" && week.Building != want {
		return fmt.Errorf("building must be %s", want)
	}
	if len(week.Days) == 0 {
		return errors.New("at least one menu day is required")
	}
	if week.WeekOf == "" {
		first, err := time.ParseInLocation("2006-01-02", week.Days[0].Date, location)
		if err != nil {
			return errors.New("weekOf or a valid first day is required")
		}
		for first.Weekday() != time.Monday {
			first = first.AddDate(0, 0, -1)
		}
		week.WeekOf = first.Format("2006-01-02")
	}
	monday, err := time.ParseInLocation("2006-01-02", week.WeekOf, location)
	if err != nil || monday.Weekday() != time.Monday {
		return errors.New("weekOf must be a Monday in YYYY-MM-DD format")
	}

	seen := make(map[string]struct{})
	normalized := make([]mealDay, 0, len(week.Days))
	for _, day := range week.Days {
		date, err := time.ParseInLocation("2006-01-02", day.Date, location)
		if err != nil || date.Before(monday) || date.After(monday.AddDate(0, 0, 6)) {
			return fmt.Errorf("day %q is outside week %s", day.Date, week.WeekOf)
		}
		if _, duplicate := seen[day.Date]; duplicate {
			continue
		}
		seen[day.Date] = struct{}{}
		day.Weekday = chineseWeekday(date.Weekday())
		normalizeMealPeriod(&day.Lunch, day.Date, "lunch")
		normalizeMealPeriod(&day.Dinner, day.Date, "dinner")
		normalized = append(normalized, day)
	}
	sort.Slice(normalized, func(i, j int) bool { return normalized[i].Date < normalized[j].Date })
	week.Days = normalized
	// 来源标签由菜单文件自己带。以前这里有个写死的默认值,那是部署者
	// 自己食堂的名字,不该出现在开源代码里。
	week.Source = cleanField(week.Source, 96)
	week.Updated = now.In(location).Format(time.RFC3339)
	return nil
}

func normalizeMealPeriod(period *mealPeriod, date, meal string) {
	outlets := make([]mealOutlet, 0, len(period.Outlets))
	for _, outlet := range period.Outlets {
		outlet.Name = cleanField(outlet.Name, 96)
		outlet.Floor = normalizeFloor(outlet.Floor, outlet.Name)
		if outlet.Floor == "" || strings.Contains(outlet.Name, "温馨提示") {
			continue
		}
		outlet.Dishes = cleanStrings(outlet.Dishes, 24, 80)
		outlets = append(outlets, outlet)
	}
	period.Outlets = outlets
	period.RecommendedFloor, period.Recommendation = recommendFloor(outlets, date, meal)
}

func recommendFloor(outlets []mealOutlet, date, meal string) (string, string) {
	type floorInfo struct {
		dishes  []string
		outlets []string
	}
	floors := make(map[string]*floorInfo)
	for _, outlet := range outlets {
		info := floors[outlet.Floor]
		if info == nil {
			info = &floorInfo{}
			floors[outlet.Floor] = info
		}
		if outlet.Name != "" {
			info.outlets = appendUnique(info.outlets, outlet.Name)
		}
		for _, dish := range outlet.Dishes {
			info.dishes = appendUnique(info.dishes, dish)
		}
	}
	if len(floors) == 0 {
		return "", ""
	}
	candidates := make([]string, 0, len(floors))
	for floor := range floors {
		candidates = append(candidates, floor)
	}
	sort.Slice(candidates, func(i, j int) bool {
		return floorNumber(candidates[i]) < floorNumber(candidates[j])
	})
	seed := 0
	for _, b := range []byte(date + "/" + meal) {
		seed += int(b)
	}
	floor := candidates[seed%len(candidates)]
	info := floors[floor]
	parts := info.dishes
	if len(parts) == 0 {
		parts = info.outlets
	}
	if len(parts) > 3 {
		parts = parts[:3]
	}
	return floor, strings.Join(parts, "、")
}

func normalizeFloor(floor, name string) string {
	source := strings.TrimSpace(floor)
	if source == "" {
		source = name
	}
	match := mealFloorPattern.FindStringSubmatch(source)
	if len(match) < 2 {
		return ""
	}
	return match[1] + "层"
}

func floorNumber(floor string) int {
	match := mealFloorPattern.FindStringSubmatch(floor)
	if len(match) < 2 {
		return 999
	}
	value, _ := strconv.Atoi(match[1])
	return value
}

func cleanStrings(values []string, limit, maxRunes int) []string {
	out := make([]string, 0, min(len(values), limit))
	for _, value := range values {
		value = cleanField(value, maxRunes)
		if value == "" {
			continue
		}
		out = appendUnique(out, value)
		if len(out) >= limit {
			break
		}
	}
	return out
}

func appendUnique(values []string, value string) []string {
	for _, existing := range values {
		if existing == value {
			return values
		}
	}
	return append(values, value)
}

func chineseWeekday(day time.Weekday) string {
	switch day {
	case time.Monday:
		return "周一"
	case time.Tuesday:
		return "周二"
	case time.Wednesday:
		return "周三"
	case time.Thursday:
		return "周四"
	case time.Friday:
		return "周五"
	case time.Saturday:
		return "周六"
	default:
		return "周日"
	}
}

func cloneMealWeeks(weeks []mealWeek, limit int) []mealWeek {
	if limit > len(weeks) {
		limit = len(weeks)
	}
	data, _ := json.Marshal(weeks[:limit])
	var cloned []mealWeek
	_ = json.Unmarshal(data, &cloned)
	return cloned
}

func (h *mealHub) load() {
	if h.statePath == "" {
		return
	}
	data, err := os.ReadFile(h.statePath)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			log.Printf("read meal state: %v", err)
		}
		return
	}
	var state mealStateFile
	if json.Unmarshal(data, &state) != nil {
		log.Printf("decode meal state: invalid JSON")
		return
	}
	h.weeks = state.Weeks
	if state.Sent != nil {
		h.sent = state.Sent
	}
}

// Must be called while h.mu is held.
func (h *mealHub) saveLocked() {
	if h.statePath == "" {
		return
	}
	state := mealStateFile{Version: 1, Weeks: h.weeks, Sent: h.sent}
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		log.Printf("encode meal state: %v", err)
		return
	}
	if err := os.MkdirAll(filepath.Dir(h.statePath), 0700); err != nil {
		log.Printf("create meal state directory: %v", err)
		return
	}
	tmp := h.statePath + ".tmp"
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		log.Printf("write meal state: %v", err)
		return
	}
	if err := os.Rename(tmp, h.statePath); err != nil {
		log.Printf("replace meal state: %v", err)
	}
}

func (h *mealHub) pruneSentLocked(before time.Time) {
	for key, raw := range h.sent {
		sent, err := time.Parse(time.RFC3339, raw)
		if err != nil || sent.Before(before) {
			delete(h.sent, key)
		}
	}
}

func requestIsLoopback(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func defaultMealStatePath() string {
	dir, err := os.UserConfigDir()
	if err != nil || dir == "" {
		return ""
	}
	return filepath.Join(dir, "folotoy", "meal-menu.json")
}
