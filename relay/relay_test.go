package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestTokenGeneration(t *testing.T) {
	token1, err := generateToken()
	if err != nil {
		t.Fatal("Token generation failed:", err)
	}
	token2, err := generateToken()
	if err != nil {
		t.Fatal("Token generation failed:", err)
	}
	if token1 == token2 {
		t.Fatal("Two tokens are identical - not random")
	}
	if len(token1) != 64 {
		t.Fatalf("Token length wrong: got %d, want 64", len(token1))
	}
	t.Logf("Token 1: %s", token1)
	t.Logf("Token 2: %s", token2)
	t.Log("Token generation: PASSED")
}

func TestMissingToken(t *testing.T) {
	req := httptest.NewRequest("GET", "/developer", nil)
	w := httptest.NewRecorder()
	developerHandler(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("Expected 400, got %d", w.Code)
	}
	t.Log("Missing token rejection: PASSED")
}

func TestInvalidToken(t *testing.T) {
	req := httptest.NewRequest("GET", "/developer?token=invalid123", nil)
	w := httptest.NewRecorder()
	developerHandler(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("Expected 401, got %d", w.Code)
	}
	t.Log("Invalid token rejection: PASSED")
}

func TestFullSessionFlow(t *testing.T) {
	// Start a real test server
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/runner") {
			runnerHandler(w, r)
		} else if strings.HasPrefix(r.URL.Path, "/developer") {
			developerHandler(w, r)
		}
	}))
	defer server.Close()

	// Convert http URL to ws URL
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http")

	// Step 1: Runner connects
	runnerConn, _, err := websocket.DefaultDialer.Dial(wsURL+"/runner", nil)
	if err != nil {
		t.Fatal("Runner failed to connect:", err)
	}
	defer runnerConn.Close()

	// Step 2: Runner receives token
	_, msg, err := runnerConn.ReadMessage()
	if err != nil {
		t.Fatal("Runner failed to read token:", err)
	}
	if !strings.HasPrefix(string(msg), "TOKEN:") {
		t.Fatalf("Expected TOKEN: prefix, got: %s", msg)
	}
	token := strings.TrimPrefix(string(msg), "TOKEN:")
	t.Logf("Token received by runner: %s", token)

	// Step 3: Developer connects with token
	devConn, _, err := websocket.DefaultDialer.Dial(
		wsURL+"/developer?token="+token, nil)
	if err != nil {
		t.Fatal("Developer failed to connect:", err)
	}
	defer devConn.Close()

	// Step 4: Send message from runner to developer
	time.Sleep(500 * time.Millisecond) // let bridge form
	testMessage := "hello from runner"
	err = runnerConn.WriteMessage(websocket.TextMessage, []byte(testMessage))
	if err != nil {
		t.Fatal("Runner failed to send message:", err)
	}

	// Step 5: Developer receives the message
	devConn.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, received, err := devConn.ReadMessage()
	if err != nil {
		t.Fatal("Developer failed to receive message:", err)
	}
	if string(received) != testMessage {
		t.Fatalf("Message mismatch: got %q, want %q", received, testMessage)
	}

	t.Logf("Message bridged successfully: %q", received)
	t.Log("Full session flow: PASSED")
}