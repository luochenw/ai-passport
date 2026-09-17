package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func TestAplusCollectorFetchesCalendarAndMenusWithSessionCookie(t *testing.T) {
	t.Parallel()
	var mu sync.Mutex
	details := make(map[string]aplusDetailRequest)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Cookie"); got != "session_id=session-fixture" {
			t.Errorf("Cookie=%q", got)
		}
		if got := r.Header.Get("Authorization"); got != "" {
			t.Errorf("unexpected Authorization=%q", got)
		}
		switch r.URL.Path {
		case "/smartcanteen/app/mini-program/h5/user_info":
			writeAplusFixture(w, map[string]any{"code": 200, "data": map[string]any{"name": "example"}})
		case "/smartcanteen/app/mini-program/menu/buildingAndSubscription":
			if got := r.URL.Query().Get("buildingCode"); got != "building-fixture" {
				t.Errorf("buildingCode=%q", got)
			}
			writeAplusFixture(w, map[string]any{
				"code": 200,
				"data": map[string]any{
					"buffetRuleInfo": map[string]any{
						"buildingCode": "building-fixture",
						"buildingName": "示例大厦",
						"meals": []map[string]any{
							{"mealRuleName": "早餐", "timeCode": "breakfast"},
							{"mealRuleName": "午餐", "timeCode": "lunch"},
							{"mealRuleName": "晚餐", "timeCode": "dinner"},
						},
					},
					"menuCalendar": []map[string]any{
						{"available": true, "canShow": true, "date": "2026-09-08", "availableTimes": []string{"lunch", "dinner"}},
						{"available": true, "canShow": true, "date": "2026-09-09", "availableTimes": []string{"lunch", "dinner"}},
					},
				},
			})
		case "/smartcanteen/app/mini-program/menu/detail/v3":
			if r.Method != http.MethodPost {
				t.Errorf("method=%s", r.Method)
			}
			var request aplusDetailRequest
			if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
				t.Errorf("decode request: %v", err)
			}
			mu.Lock()
			details[request.MenuDate+"/"+request.TimeCode] = request
			mu.Unlock()
			writeAplusFixture(w, map[string]any{
				"code": 200,
				"data": map[string]any{
					"buildingCode": request.BuildingCode,
					"buildingName": "示例大厦",
					"mealTimeCode": request.TimeCode,
					"menuSites": []map[string]any{
						{
							"siteLabel":        "2层-示例档口",
							"boxMealItems":     []map[string]any{{"foodName": "示例套餐"}},
							"selfServiceItems": []map[string]any{{"foodName": "示例小炒"}, {"foodName": "示例小炒"}},
						},
					},
				},
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	collector := newAplusCollector("session-fixture", "building-fixture")
	collector.baseURL = server.URL
	collector.httpClient = server.Client()
	location := time.FixedZone("Asia/Shanghai", 8*60*60)
	weeks, err := collector.Fetch(context.Background(), location)
	if err != nil {
		t.Fatal(err)
	}
	if len(weeks) != 1 || weeks[0].WeekOf != "2026-09-07" || weeks[0].Building != "示例大厦" {
		t.Fatalf("unexpected weeks: %+v", weeks)
	}
	if got := weeks[0].Days[0].Lunch.Outlets[0].Dishes; len(got) != 2 || got[0] != "示例套餐" || got[1] != "示例小炒" {
		t.Fatalf("unexpected dishes: %#v", got)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(details) != 4 {
		t.Fatalf("detail request count=%d", len(details))
	}
	for key, request := range details {
		if request.BuildingCode != "building-fixture" || (request.TimeCode != "lunch" && request.TimeCode != "dinner") {
			t.Fatalf("detail %s: %+v", key, request)
		}
	}
}

func TestAplusCollectorClassifiesOnlyAuthenticationFailures(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name     string
		response map[string]any
		status   int
		wantAuth bool
	}{
		{name: "http unauthorized", status: http.StatusUnauthorized, wantAuth: true},
		{name: "api forbidden", status: http.StatusOK, response: map[string]any{"code": 403, "message": "forbidden"}, wantAuth: true},
		{name: "explicit login expired", status: http.StatusOK, response: map[string]any{"code": 500, "message": "登录已失效"}, wantAuth: true},
		{name: "ordinary api failure", status: http.StatusOK, response: map[string]any{"code": 500, "message": "服务繁忙"}, wantAuth: false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(test.status)
				if test.response != nil {
					_ = json.NewEncoder(w).Encode(test.response)
				}
			}))
			defer server.Close()
			collector := newAplusCollector("session-fixture", "building-fixture")
			collector.baseURL = server.URL
			collector.httpClient = server.Client()
			err := collector.get(context.Background(), "/probe", nil)
			if got := errors.Is(err, errAplusAuthentication); got != test.wantAuth {
				t.Fatalf("error=%v auth=%v", err, got)
			}
		})
	}
}

func TestAplusSyncerNotifiesOnceForAuthenticationButNotNetworkErrors(t *testing.T) {
	t.Parallel()
	authServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer authServer.Close()
	collector := newAplusCollector("session-fixture", "building-fixture")
	collector.baseURL = authServer.URL
	collector.httpClient = authServer.Client()
	notifier := &recordingAplusNotifier{}
	syncer := &aplusSyncer{
		collector: collector,
		sink:      &recordingAplusSink{},
		notifier:  notifier,
		location:  time.UTC,
		now:       func() time.Time { return time.Date(2026, 9, 8, 12, 0, 0, 0, time.UTC) },
	}
	for range 2 {
		if err := syncer.SyncOnce(context.Background()); !errors.Is(err, errAplusAuthentication) {
			t.Fatalf("error=%v", err)
		}
	}
	if notifier.count != 1 || notifier.last.Type != "aplus_token_expired" {
		t.Fatalf("notifications=%d event=%+v", notifier.count, notifier.last)
	}

	networkCollector := newAplusCollector("session-fixture", "building-fixture")
	networkCollector.baseURL = "http://aplus.invalid"
	networkCollector.httpClient = &http.Client{Transport: errorRoundTripper{}}
	networkNotifier := &recordingAplusNotifier{}
	networkSyncer := &aplusSyncer{
		collector: networkCollector, sink: &recordingAplusSink{}, notifier: networkNotifier, location: time.UTC,
	}
	if err := networkSyncer.SyncOnce(context.Background()); err == nil || errors.Is(err, errAplusAuthentication) {
		t.Fatalf("network error=%v", err)
	}
	if networkNotifier.count != 0 {
		t.Fatalf("network error sent %d notifications", networkNotifier.count)
	}
}

func TestFeishuWebhookNotifierSendsTextAndChecksResponseCode(t *testing.T) {
	t.Parallel()
	var received feishuWebhookMessage
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Errorf("method=%s", r.Method)
		}
		if got := r.Header.Get("Content-Type"); !strings.HasPrefix(got, "application/json") {
			t.Errorf("Content-Type=%q", got)
		}
		if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
			t.Errorf("decode body: %v", err)
		}
		writeAplusFixture(w, map[string]any{"code": 0, "msg": "success"})
	}))
	defer server.Close()
	notifier, err := newAplusAuthNotifier(server.URL + "/hook/secret-fixture")
	if err != nil {
		t.Fatal(err)
	}
	event := aplusTokenExpiredEvent{
		Type: "aplus_token_expired", Source: "aplus_canteen",
		OccurredAt: "2026-09-08T12:00:00+08:00", Message: "登录态已失效",
	}
	if err := notifier.NotifyTokenExpired(context.Background(), event); err != nil {
		t.Fatal(err)
	}
	if received.MessageType != "text" || received.Content.Text != "登录态已失效\n时间：2026-09-08T12:00:00+08:00" {
		t.Fatalf("message=%+v", received)
	}
}

func TestFeishuWebhookNotifierRejectsHTTPAndAPIErrorWithoutLeakingURL(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name   string
		status int
		body   map[string]any
	}{
		{name: "http", status: http.StatusBadGateway, body: map[string]any{"code": 0}},
		{name: "api", status: http.StatusOK, body: map[string]any{"code": 19001}},
		{name: "missing code", status: http.StatusOK, body: map[string]any{"msg": "invalid"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(test.status)
				_ = json.NewEncoder(w).Encode(test.body)
			}))
			defer server.Close()
			secret := "secret-fixture"
			notifier := feishuWebhookNotifier{endpoint: server.URL + "/" + secret, httpClient: server.Client()}
			err := notifier.NotifyTokenExpired(context.Background(), aplusTokenExpiredEvent{Message: "expired"})
			if err == nil {
				t.Fatal("expected notification error")
			}
			if strings.Contains(err.Error(), secret) || strings.Contains(err.Error(), server.URL) {
				t.Fatalf("error leaked webhook URL: %v", err)
			}
		})
	}
}

func TestWebsocketAplusNotifierSendsGenericJSONEvent(t *testing.T) {
	t.Parallel()
	received := make(chan aplusTokenExpiredEvent, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer conn.CloseNow()
		_, data, err := conn.Read(r.Context())
		if err != nil {
			return
		}
		var event aplusTokenExpiredEvent
		if json.Unmarshal(data, &event) == nil {
			received <- event
		}
	}))
	defer server.Close()
	event := aplusTokenExpiredEvent{
		Type: "aplus_token_expired", Source: "aplus_canteen",
		OccurredAt: "2026-09-08T12:00:00+08:00", Message: "refresh",
	}
	notifier := websocketAplusNotifier{endpoint: strings.Replace(server.URL, "http://", "ws://", 1)}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := notifier.NotifyTokenExpired(ctx, event); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-received:
		if got != event {
			t.Fatalf("event=%+v", got)
		}
	case <-ctx.Done():
		t.Fatal("notification was not received")
	}
}

func TestMealHubStoresCollectorWeeksAndPersists(t *testing.T) {
	t.Parallel()
	statePath := filepath.Join(t.TempDir(), "meal-state.json")
	hub := newMealHub(statePath)
	hub.now = func() time.Time { return time.Date(2026, 9, 8, 12, 0, 0, 0, hub.location) }
	week := mealWeek{
		WeekOf: "2026-09-07", Building: "示例大厦", Source: "Aplus",
		Days: []mealDay{{
			Date:  "2026-09-08",
			Lunch: mealPeriod{Outlets: []mealOutlet{{Floor: "2层-示例档口", Name: "2层-示例档口", Dishes: []string{"示例套餐"}}}},
		}},
	}
	if err := hub.StoreMealWeeks([]mealWeek{week}); err != nil {
		t.Fatal(err)
	}
	if len(hub.weeks) != 1 || hub.weeks[0].Days[0].Lunch.RecommendedFloor != "2层" {
		t.Fatalf("stored weeks=%+v", hub.weeks)
	}
	data, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"source": "Aplus"`) {
		t.Fatalf("state=%s", data)
	}
}

func writeAplusFixture(w http.ResponseWriter, value any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(value)
}

type recordingAplusNotifier struct {
	count int
	last  aplusTokenExpiredEvent
}

func (n *recordingAplusNotifier) NotifyTokenExpired(_ context.Context, event aplusTokenExpiredEvent) error {
	n.count++
	n.last = event
	return nil
}

type recordingAplusSink struct {
	weeks []mealWeek
}

func (s *recordingAplusSink) StoreMealWeeks(weeks []mealWeek) error {
	s.weeks = append(s.weeks, weeks...)
	return nil
}

type errorRoundTripper struct{}

func (errorRoundTripper) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, errors.New("synthetic network failure")
}
