package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// 测试里用的楼名。是个假名字 —— 这是开源仓库,夹具里不该出现真实的
// 办公楼。真实值由部署时的 MEAL_BUILDING 决定,见 mealBuildingName()。
//
// ⚠ 同样的规矩对**楼层号、档口名、菜名**一样成立,而且更容易漏。楼名一眼
// 就知道该改,底下那几行看着只是"随便编的测试数据" —— 但"哪层有什么档口、
// 卖什么菜"这个组合是一栋楼的指纹,在那儿上过班的人一眼认得出来,比楼名
// 还具体。所以下面全部用 `示例` 开头的合成值,只保留代码真正依赖的形状:
// `N层` 要能被 mealFloorPattern 匹配,同一层挂两个档口才测得出推荐逻辑。
const wantBuilding = "示例大厦"

func testMealWeek() mealWeek {
	return mealWeek{
		WeekOf:   "2026-08-31",
		Building: wantBuilding,
		Days: []mealDay{{
			Date: "2026-09-03",
			Lunch: mealPeriod{Outlets: []mealOutlet{
				{Floor: "2层", Name: "2层-示例面档", Dishes: []string{"示例面"}},
				{Floor: "3层", Name: "3层-示例饺子档", Dishes: []string{"示例水饺甲", "示例水饺乙"}},
				{Floor: "3层", Name: "3层-示例汤粉档", Dishes: []string{"示例汤粉"}},
			}},
			Dinner: mealPeriod{Outlets: []mealOutlet{
				{Floor: "5层", Name: "5层-示例烧腊档", Dishes: []string{"示例烧腊", "示例例汤"}},
			}},
		}},
	}
}

func TestNormalizeMealWeekAndRecommendation(t *testing.T) {
	week := testMealWeek()
	now := time.Date(2026, 9, 3, 10, 0, 0, 0, time.FixedZone("CST", 8*60*60))
	if err := normalizeMealWeek(&week, now.Location(), now); err != nil {
		t.Fatal(err)
	}
	if got := week.Days[0].Weekday; got != "周四" {
		t.Fatalf("weekday=%q", got)
	}
	if got := week.Days[0].Lunch.RecommendedFloor; got != "3层" {
		t.Fatalf("lunch floor=%q", got)
	}
	if got := week.Days[0].Dinner.RecommendedFloor; got != "5层" {
		t.Fatalf("dinner floor=%q", got)
	}
}

func TestNormalizeMealWeekRejectsAnotherBuilding(t *testing.T) {
	// 楼名校验默认是**关**的(不设 MEAL_BUILDING 就不校验,菜单文件写什么
	// 是什么)—— 这样开源仓库里不用写死任何一栋真实的办公楼。
	// 这条测的是"设了之后确实会挡",所以要显式设上。
	t.Setenv("MEAL_BUILDING", wantBuilding)
	week := testMealWeek()
	week.Building = "其他楼宇"
	now := time.Date(2026, 9, 3, 10, 0, 0, 0, time.FixedZone("CST", 8*60*60))
	if err := normalizeMealWeek(&week, now.Location(), now); err == nil ||
		!strings.Contains(err.Error(), wantBuilding) {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestMealBroadcastOnlyInstalledAndDeduplicates(t *testing.T) {
	hub := newMealHub("")
	week := testMealWeek()
	now := time.Date(2026, 9, 3, 12, 10, 0, 0, hub.location)
	if err := normalizeMealWeek(&week, hub.location, now); err != nil {
		t.Fatal(err)
	}
	hub.weeks = []mealWeek{week}

	mux := http.NewServeMux()
	mux.HandleFunc("/v1/meals/ws", hub.handleWebSocket)
	server := httptest.NewServer(mux)
	defer server.Close()

	installed := dialMealClient(t, server.URL, "installed", true)
	defer installed.CloseNow()
	readMealEvent(t, installed, "meal_state")

	notInstalled := dialMealClient(t, server.URL, "not-installed", false)
	defer notInstalled.CloseNow()

	reminder, subscribers, ok := hub.broadcastReminder(now, "lunch", true)
	if !ok || subscribers != 1 {
		t.Fatalf("broadcast ok=%v subscribers=%d", ok, subscribers)
	}
	if reminder.Floor != "3层" {
		t.Fatalf("floor=%q", reminder.Floor)
	}
	event := readMealEvent(t, installed, "meal_reminder")
	if event.Reminder == nil || event.Reminder.Floor != "3层" {
		t.Fatalf("unexpected reminder: %+v", event.Reminder)
	}
	if _, _, duplicated := hub.broadcastReminder(now, "lunch", true); duplicated {
		t.Fatal("same client should not receive the same meal slot twice")
	}
}

func TestMealUpdateEndpointKeepsHistory(t *testing.T) {
	hub := newMealHub("")
	// 菜单写入仍以 loopback 为边界，不要求读取用的 Bearer 口令。
	hub.sharedToken = "meal-secret"
	hub.now = func() time.Time {
		return time.Date(2026, 9, 3, 11, 0, 0, 0, hub.location)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/meals/update", hub.handleUpdate)

	body, _ := json.Marshal(testMealWeek())
	request := httptest.NewRequest(http.MethodPost, "/v1/meals/update", strings.NewReader(string(body)))
	request.RemoteAddr = "127.0.0.1:12345"
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	if len(hub.weeks) != 1 || hub.weeks[0].Days[0].Lunch.RecommendedFloor != "3层" {
		t.Fatalf("unexpected stored menu: %+v", hub.weeks)
	}

	second := testMealWeek()
	second.Days[0].Date = "2026-09-04"
	secondBody, _ := json.Marshal(second)
	secondRequest := httptest.NewRequest(
		http.MethodPost, "/v1/meals/update", strings.NewReader(string(secondBody)))
	secondRequest.RemoteAddr = "127.0.0.1:12345"
	secondRecorder := httptest.NewRecorder()
	mux.ServeHTTP(secondRecorder, secondRequest)
	if secondRecorder.Code != http.StatusOK || len(hub.weeks[0].Days) != 2 {
		t.Fatalf("partial week update should merge days: status=%d days=%d",
			secondRecorder.Code, len(hub.weeks[0].Days))
	}
}

func TestMealReadEndpointsRequireBearerToken(t *testing.T) {
	hub := newMealHub("")
	hub.sharedToken = "meal-secret"
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/meals/current", hub.handleCurrent)
	mux.HandleFunc("/v1/meals/weeks", hub.handleWeeks)

	for _, path := range []string{"/v1/meals/current", "/v1/meals/weeks"} {
		for _, authorization := range []string{"", "Bearer wrong"} {
			request := httptest.NewRequest(http.MethodGet, path, nil)
			request.Header.Set("Authorization", authorization)
			recorder := httptest.NewRecorder()
			mux.ServeHTTP(recorder, request)
			if recorder.Code != http.StatusUnauthorized {
				t.Fatalf("path=%s auth=%q status=%d", path, authorization, recorder.Code)
			}
		}

		request := httptest.NewRequest(http.MethodGet, path, nil)
		request.Header.Set("Authorization", "Bearer meal-secret")
		recorder := httptest.NewRecorder()
		mux.ServeHTTP(recorder, request)
		if recorder.Code != http.StatusOK {
			t.Fatalf("authorized path=%s status=%d body=%s",
				path, recorder.Code, recorder.Body.String())
		}
	}
}

func TestMealReadAuthDisabledWhenTokenEmpty(t *testing.T) {
	hub := newMealHub("")
	hub.sharedToken = ""
	request := httptest.NewRequest(http.MethodGet, "/v1/meals/current", nil)
	recorder := httptest.NewRecorder()
	hub.handleCurrent(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}

func TestMealWebSocketRequiresJoinToken(t *testing.T) {
	hub := newMealHub("")
	hub.sharedToken = "meal-secret"
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/meals/ws", hub.handleWebSocket)
	server := httptest.NewServer(mux)
	defer server.Close()

	unauthorized := dialMealClientWithToken(t, server.URL, "bad-token", true, "wrong")
	defer unauthorized.CloseNow()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_, _, err := unauthorized.Read(ctx)
	if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("unexpected unauthorized websocket error: %v", err)
	}

	authorized := dialMealClientWithToken(t, server.URL, "good-token", true, "meal-secret")
	defer authorized.CloseNow()
	readMealEvent(t, authorized, "meal_state")
}

func dialMealClient(t *testing.T, serverURL, id string, installed bool) *websocket.Conn {
	return dialMealClientWithToken(t, serverURL, id, installed, "")
}

func dialMealClientWithToken(
	t *testing.T, serverURL, id string, installed bool, token string,
) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx,
		strings.Replace(serverURL, "http://", "ws://", 1)+"/v1/meals/ws", nil)
	if err != nil {
		t.Fatal(err)
	}
	message, _ := json.Marshal(mealClientMessage{
		Type: "join", ClientID: id, Installed: installed, Token: token,
	})
	if err := conn.Write(ctx, websocket.MessageText, message); err != nil {
		t.Fatal(err)
	}
	return conn
}

func readMealEvent(t *testing.T, conn *websocket.Conn, wanted string) mealServerEvent {
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
		var event mealServerEvent
		if json.Unmarshal(data, &event) == nil && event.Type == wanted {
			return event
		}
	}
}
