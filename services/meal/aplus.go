package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

const (
	defaultAplusBaseURL      = "https://aplus.bytedance.com"
	defaultAplusPollInterval = 30 * time.Minute
	maxAplusMenuDates        = 31
)

var errAplusAuthentication = errors.New("Aplus authentication expired")

type aplusCollector struct {
	baseURL      string
	sessionID    string
	buildingCode string
	httpClient   *http.Client
}

type aplusEnvelope struct {
	Code    json.RawMessage `json:"code"`
	Message string          `json:"message"`
	Msg     string          `json:"msg"`
	Data    json.RawMessage `json:"data"`
}

type aplusBuildingData struct {
	BuffetRuleInfo struct {
		BuildingCode string `json:"buildingCode"`
		BuildingName string `json:"buildingName"`
		Meals        []struct {
			MealRuleName string `json:"mealRuleName"`
			TimeCode     string `json:"timeCode"`
		} `json:"meals"`
	} `json:"buffetRuleInfo"`
	MenuCalendar []struct {
		Available      bool     `json:"available"`
		AvailableTimes []string `json:"availableTimes"`
		CanShow        bool     `json:"canShow"`
		Date           string   `json:"date"`
	} `json:"menuCalendar"`
}

type aplusMenuDetail struct {
	BuildingCode string `json:"buildingCode"`
	BuildingName string `json:"buildingName"`
	MealTimeCode string `json:"mealTimeCode"`
	MealTimeName string `json:"mealTimeName"`
	MenuSites    []struct {
		SiteLabel    string `json:"siteLabel"`
		BoxMealItems []struct {
			FoodName string `json:"foodName"`
		} `json:"boxMealItems"`
		SelfServiceItems []struct {
			FoodName string `json:"foodName"`
		} `json:"selfServiceItems"`
	} `json:"menuSites"`
}

type aplusDetailRequest struct {
	BuildingCode string `json:"buildingCode"`
	MenuDate     string `json:"menuDate"`
	TimeCode     string `json:"timeCode"`
}

func newAplusCollector(sessionID, buildingCode string) *aplusCollector {
	return &aplusCollector{
		baseURL:      defaultAplusBaseURL,
		sessionID:    sessionID,
		buildingCode: buildingCode,
		httpClient:   &http.Client{Timeout: 20 * time.Second},
	}
}

// Fetch verifies the session, reads the building calendar and downloads each
// lunch/dinner menu exposed by that calendar. Credentials are deliberately
// kept out of returned errors so callers can safely log them.
func (c *aplusCollector) Fetch(ctx context.Context, location *time.Location) ([]mealWeek, error) {
	if strings.TrimSpace(c.sessionID) == "" || strings.TrimSpace(c.buildingCode) == "" {
		return nil, errors.New("Aplus collector configuration is incomplete")
	}
	if location == nil {
		location = time.FixedZone("Asia/Shanghai", 8*60*60)
	}

	if err := c.get(ctx, "/smartcanteen/app/mini-program/h5/user_info", nil); err != nil {
		return nil, fmt.Errorf("verify Aplus session: %w", err)
	}

	query := url.Values{"buildingCode": []string{c.buildingCode}}
	var building aplusBuildingData
	if err := c.get(ctx, "/smartcanteen/app/mini-program/menu/buildingAndSubscription", &building, query); err != nil {
		return nil, fmt.Errorf("fetch Aplus menu calendar: %w", err)
	}

	mealCodes := make(map[string]string, 2)
	for _, meal := range building.BuffetRuleInfo.Meals {
		kind := strings.ToLower(strings.TrimSpace(meal.TimeCode))
		switch kind {
		case "lunch", "dinner":
			mealCodes[kind] = meal.TimeCode
		}
	}
	if len(mealCodes) == 0 {
		return nil, errors.New("Aplus menu calendar has no lunch or dinner rules")
	}

	buildingName := strings.TrimSpace(building.BuffetRuleInfo.BuildingName)
	if buildingName == "" {
		buildingName = c.buildingCode
	}
	type dateMenus struct {
		lunch  mealPeriod
		dinner mealPeriod
	}
	menus := make(map[string]*dateMenus)
	dates := make([]string, 0, len(building.MenuCalendar))
	seenDates := make(map[string]struct{})
	availableTimes := make(map[string]map[string]struct{})
	for _, calendar := range building.MenuCalendar {
		date := strings.TrimSpace(calendar.Date)
		if _, err := time.ParseInLocation("2006-01-02", date, location); err != nil {
			continue
		}
		if !calendar.Available || !calendar.CanShow {
			continue
		}
		if _, seen := seenDates[date]; seen {
			continue
		}
		seenDates[date] = struct{}{}
		dates = append(dates, date)
		if len(calendar.AvailableTimes) != 0 {
			availableTimes[date] = make(map[string]struct{}, len(calendar.AvailableTimes))
			for _, timeCode := range calendar.AvailableTimes {
				availableTimes[date][strings.ToLower(strings.TrimSpace(timeCode))] = struct{}{}
			}
		}
	}
	sort.Strings(dates)
	if len(dates) > maxAplusMenuDates {
		dates = dates[:maxAplusMenuDates]
	}

	for _, date := range dates {
		day := &dateMenus{}
		for _, kind := range []string{"lunch", "dinner"} {
			timeCode, ok := mealCodes[kind]
			if !ok {
				continue
			}
			if available := availableTimes[date]; available != nil {
				if _, ok := available[strings.ToLower(timeCode)]; !ok {
					continue
				}
			}
			var detail aplusMenuDetail
			body := aplusDetailRequest{BuildingCode: c.buildingCode, MenuDate: date, TimeCode: timeCode}
			if err := c.post(ctx, "/smartcanteen/app/mini-program/menu/detail/v3", body, &detail); err != nil {
				return nil, fmt.Errorf("fetch Aplus %s menu for %s: %w", kind, date, err)
			}
			period := aplusPeriod(detail)
			if kind == "lunch" {
				day.lunch = period
			} else {
				day.dinner = period
			}
		}
		menus[date] = day
	}

	weeks := make(map[string]*mealWeek)
	for _, date := range dates {
		parsed, _ := time.ParseInLocation("2006-01-02", date, location)
		monday := parsed
		for monday.Weekday() != time.Monday {
			monday = monday.AddDate(0, 0, -1)
		}
		weekOf := monday.Format("2006-01-02")
		week := weeks[weekOf]
		if week == nil {
			week = &mealWeek{WeekOf: weekOf, Building: buildingName, Source: "Aplus"}
			weeks[weekOf] = week
		}
		day := menus[date]
		week.Days = append(week.Days, mealDay{Date: date, Lunch: day.lunch, Dinner: day.dinner})
	}
	result := make([]mealWeek, 0, len(weeks))
	for _, week := range weeks {
		result = append(result, *week)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].WeekOf > result[j].WeekOf })
	if len(result) == 0 {
		return nil, errors.New("Aplus menu calendar contains no valid dates")
	}
	return result, nil
}

func aplusPeriod(detail aplusMenuDetail) mealPeriod {
	period := mealPeriod{Outlets: make([]mealOutlet, 0, len(detail.MenuSites))}
	for _, site := range detail.MenuSites {
		label := strings.TrimSpace(site.SiteLabel)
		dishes := make([]string, 0, len(site.BoxMealItems)+len(site.SelfServiceItems))
		for _, item := range site.BoxMealItems {
			dishes = appendUnique(dishes, strings.TrimSpace(item.FoodName))
		}
		for _, item := range site.SelfServiceItems {
			dishes = appendUnique(dishes, strings.TrimSpace(item.FoodName))
		}
		period.Outlets = append(period.Outlets, mealOutlet{Floor: label, Name: label, Dishes: dishes})
	}
	return period
}

func (c *aplusCollector) get(ctx context.Context, path string, destination any, queries ...url.Values) error {
	endpoint, err := c.endpoint(path, queries...)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return errors.New("build Aplus request")
	}
	return c.do(req, destination)
}

func (c *aplusCollector) post(ctx context.Context, path string, body any, destination any) error {
	data, err := json.Marshal(body)
	if err != nil {
		return errors.New("encode Aplus request")
	}
	endpoint, err := c.endpoint(path)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(data))
	if err != nil {
		return errors.New("build Aplus request")
	}
	req.Header.Set("Content-Type", "application/json")
	return c.do(req, destination)
}

func (c *aplusCollector) endpoint(path string, queries ...url.Values) (string, error) {
	base, err := url.Parse(c.baseURL)
	if err != nil {
		return "", errors.New("invalid Aplus base URL")
	}
	base.Path = path
	if len(queries) != 0 {
		base.RawQuery = queries[0].Encode()
	}
	return base.String(), nil
}

func (c *aplusCollector) do(req *http.Request, destination any) error {
	req.Header.Set("Accept", "application/json, text/plain, */*")
	req.Header.Set("Cookie", (&http.Cookie{Name: "session_id", Value: c.sessionID}).String())
	req.Header.Set("Referer", c.baseURL+"/canteen/menu")
	req.Header.Set("X-Accept-Language", "zh")
	req.Header.Set("X-Catering-Timezone", "GMT+8:00")
	req.Header.Set("X-Client-Type", "h5")
	req.Header.Set("X-Redirect-Url", c.baseURL+"/canteen/menu")
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return errors.New("Aplus request failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return errAplusAuthentication
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("Aplus HTTP status %d", resp.StatusCode)
	}
	decoder := json.NewDecoder(http.MaxBytesReader(nil, resp.Body, 4<<20))
	var envelope aplusEnvelope
	if err := decoder.Decode(&envelope); err != nil {
		return errors.New("decode Aplus response")
	}
	code := aplusCode(envelope.Code)
	message := strings.TrimSpace(envelope.Message + " " + envelope.Msg)
	if code == http.StatusUnauthorized || code == http.StatusForbidden || explicitAplusAuthMessage(message) {
		return errAplusAuthentication
	}
	if code != 0 && code != http.StatusOK {
		return fmt.Errorf("Aplus API code %d", code)
	}
	if destination != nil && len(envelope.Data) != 0 && string(envelope.Data) != "null" {
		if err := json.Unmarshal(envelope.Data, destination); err != nil {
			return errors.New("decode Aplus response data")
		}
	}
	return nil
}

func aplusCode(raw json.RawMessage) int {
	if len(raw) == 0 {
		return 0
	}
	var number int
	if json.Unmarshal(raw, &number) == nil {
		return number
	}
	var text string
	if json.Unmarshal(raw, &text) == nil {
		number, _ = strconv.Atoi(text)
	}
	return number
}

func explicitAplusAuthMessage(message string) bool {
	message = strings.ToLower(strings.TrimSpace(message))
	for _, marker := range []string{
		"未登录", "请先登录", "登录已失效", "登录失效", "session expired",
		"not logged in", "unauthorized", "authentication required",
	} {
		if strings.Contains(message, marker) {
			return true
		}
	}
	return false
}

type aplusTokenExpiredEvent struct {
	Type       string `json:"type"`
	Source     string `json:"source"`
	OccurredAt string `json:"occurredAt"`
	Message    string `json:"message"`
}

type aplusAuthNotifier interface {
	NotifyTokenExpired(context.Context, aplusTokenExpiredEvent) error
}

func newAplusAuthNotifier(endpoint string) (aplusAuthNotifier, error) {
	parsed, err := url.Parse(endpoint)
	if err != nil || parsed.Host == "" {
		return nil, errors.New("invalid token notification URL")
	}
	switch strings.ToLower(parsed.Scheme) {
	case "http", "https":
		return feishuWebhookNotifier{
			endpoint:   endpoint,
			httpClient: &http.Client{Timeout: 10 * time.Second},
		}, nil
	case "ws", "wss":
		return websocketAplusNotifier{endpoint: endpoint}, nil
	default:
		return nil, errors.New("unsupported token notification URL scheme")
	}
}

// feishuWebhookNotifier implements Feishu custom bot's text-message protocol.
// It never includes its endpoint in returned errors because webhook URLs carry
// a secret token.
type feishuWebhookNotifier struct {
	endpoint   string
	httpClient *http.Client
}

type feishuWebhookMessage struct {
	MessageType string `json:"msg_type"`
	Content     struct {
		Text string `json:"text"`
	} `json:"content"`
}

type feishuWebhookResponse struct {
	Code       *int `json:"code"`
	StatusCode *int `json:"StatusCode"`
}

func (n feishuWebhookNotifier) NotifyTokenExpired(ctx context.Context, event aplusTokenExpiredEvent) error {
	message := feishuWebhookMessage{MessageType: "text"}
	message.Content.Text = event.Message + "\n时间：" + event.OccurredAt
	data, err := json.Marshal(message)
	if err != nil {
		return errors.New("encode Feishu token notification")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, n.endpoint, bytes.NewReader(data))
	if err != nil {
		return errors.New("build Feishu token notification")
	}
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	resp, err := n.httpClient.Do(req)
	if err != nil {
		return errors.New("send Feishu token notification")
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("Feishu token notification HTTP status %d", resp.StatusCode)
	}
	var result feishuWebhookResponse
	if err := json.NewDecoder(http.MaxBytesReader(nil, resp.Body, 1<<20)).Decode(&result); err != nil {
		return errors.New("decode Feishu token notification response")
	}
	code := result.Code
	if code == nil {
		code = result.StatusCode
	}
	if code == nil {
		return errors.New("Feishu token notification response has no code")
	}
	if *code != 0 {
		return fmt.Errorf("Feishu token notification API code %d", *code)
	}
	return nil
}

// websocketAplusNotifier intentionally speaks only one small, generic JSON
// event. The destination-specific protocol can be replaced behind
// aplusAuthNotifier without coupling it to menu collection.
type websocketAplusNotifier struct {
	endpoint string
}

func (n websocketAplusNotifier) NotifyTokenExpired(ctx context.Context, event aplusTokenExpiredEvent) error {
	conn, _, err := websocket.Dial(ctx, n.endpoint, nil)
	if err != nil {
		return errors.New("connect token notification websocket")
	}
	defer conn.CloseNow()
	data, err := json.Marshal(event)
	if err != nil {
		return errors.New("encode token notification")
	}
	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		return errors.New("write token notification")
	}
	_ = conn.Close(websocket.StatusNormalClosure, "sent")
	return nil
}

type aplusWeekSink interface {
	StoreMealWeeks([]mealWeek) error
}

type aplusSyncer struct {
	collector    *aplusCollector
	sink         aplusWeekSink
	notifier     aplusAuthNotifier
	location     *time.Location
	now          func() time.Time
	mu           sync.Mutex
	authNotified bool
}

func (s *aplusSyncer) SyncOnce(ctx context.Context) error {
	weeks, err := s.collector.Fetch(ctx, s.location)
	if err != nil {
		if errors.Is(err, errAplusAuthentication) {
			return s.handleAuthenticationFailure(ctx, err)
		}
		return err
	}
	if err := s.sink.StoreMealWeeks(weeks); err != nil {
		return fmt.Errorf("store Aplus menus: %w", err)
	}
	s.mu.Lock()
	s.authNotified = false
	s.mu.Unlock()
	return nil
}

func (s *aplusSyncer) handleAuthenticationFailure(ctx context.Context, cause error) error {
	s.mu.Lock()
	if s.authNotified || s.notifier == nil {
		s.mu.Unlock()
		return cause
	}
	s.mu.Unlock()
	now := time.Now()
	if s.now != nil {
		now = s.now()
	}
	event := aplusTokenExpiredEvent{
		Type:       "aplus_token_expired",
		Source:     "aplus_canteen",
		OccurredAt: now.Format(time.RFC3339),
		Message:    "Aplus 登录态已失效，请刷新 APLUS_SESSION_ID",
	}
	if err := s.notifier.NotifyTokenExpired(ctx, event); err != nil {
		return fmt.Errorf("%w; token expiry notification failed", cause)
	}
	s.mu.Lock()
	s.authNotified = true
	s.mu.Unlock()
	return cause
}

func (s *aplusSyncer) Run(ctx context.Context, interval time.Duration, logf func(string, ...any)) {
	if interval <= 0 {
		interval = defaultAplusPollInterval
	}
	if logf == nil {
		logf = func(string, ...any) {}
	}
	sync := func() {
		syncCtx, cancel := context.WithTimeout(ctx, 2*time.Minute)
		defer cancel()
		if err := s.SyncOnce(syncCtx); err != nil {
			if errors.Is(err, errAplusAuthentication) {
				logf("Aplus session expired; refresh APLUS_SESSION_ID")
			} else {
				logf("Aplus menu sync failed: %v", err)
			}
			return
		}
		logf("Aplus menu sync completed")
	}
	sync()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			sync()
		}
	}
}
