package main

import (
	"crypto/rand"
	"encoding/hex"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type Session struct {
	token     string
	createdAt time.Time
	runner    *websocket.Conn
	developer *websocket.Conn
	bridged   chan struct{}
	mu        sync.Mutex
}

var (
	sessions = make(map[string]*Session)
	mu       sync.RWMutex
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool {
		return true
	},
}

func generateToken() (string, error) {
	bytes := make([]byte, 32)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return hex.EncodeToString(bytes), nil
}

func runnerHandler(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Println("Runner upgrade error:", err)
		return
	}

	token, err := generateToken()
	if err != nil {
		log.Println("Token generation error:", err)
		conn.Close()
		return
	}

	session := &Session{
		token:     token,
		createdAt: time.Now(),
		runner:    conn,
		bridged:   make(chan struct{}),
	}

	mu.Lock()
	sessions[token] = session
	mu.Unlock()

	log.Printf("Runner connected. Session token: %s", token)

	err = conn.WriteMessage(websocket.TextMessage, []byte("TOKEN:"+token))
	if err != nil {
		log.Println("Error sending token to runner:", err)
		cleanupSession(token)
		return
	}

	go func() {
		time.Sleep(30 * time.Minute)
		log.Printf("Session %s expired", token)
		cleanupSession(token)
	}()

	<-session.bridged
	log.Printf("Bridge formed for session %s", token)
}

func developerHandler(w http.ResponseWriter, r *http.Request) {
	token := r.URL.Query().Get("token")
	if token == "" {
		http.Error(w, "Missing token", http.StatusBadRequest)
		return
	}

	mu.RLock()
	session, exists := sessions[token]
	mu.RUnlock()

	if !exists {
		http.Error(w, "Invalid or expired token", http.StatusUnauthorized)
		log.Printf("Developer tried invalid token: %s", token)
		return
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Println("Developer upgrade error:", err)
		return
	}

	session.mu.Lock()
	session.developer = conn
	session.mu.Unlock()

	log.Printf("Developer connected to session %s", token)

	close(session.bridged)

	bridge(session)
}

func bridge(session *Session) {
	done := make(chan struct{}, 2)

	go func() {
		defer func() { done <- struct{}{} }()
		for {
			msgType, msg, err := session.runner.ReadMessage()
			if err != nil {
				log.Printf("Runner read error in session %s", session.token)
				return
			}
			session.mu.Lock()
			dev := session.developer
			session.mu.Unlock()
			if err := dev.WriteMessage(msgType, msg); err != nil {
				log.Printf("Developer write error in session %s", session.token)
				return
			}
		}
	}()

	go func() {
		defer func() { done <- struct{}{} }()
		for {
			msgType, msg, err := session.developer.ReadMessage()
			if err != nil {
				log.Printf("Developer read error in session %s", session.token)
				return
			}
			if err := session.runner.WriteMessage(msgType, msg); err != nil {
				log.Printf("Runner write error in session %s", session.token)
				return
			}
		}
	}()

	<-done
	cleanupSession(session.token)
}

func cleanupSession(token string) {
	mu.Lock()
	session, exists := sessions[token]
	if exists {
		delete(sessions, token)
	}
	mu.Unlock()

	if exists {
		session.mu.Lock()
		if session.runner != nil {
			session.runner.Close()
		}
		if session.developer != nil {
			session.developer.Close()
		}
		session.mu.Unlock()
		log.Printf("Session %s cleaned up", token)
	}
}

func statusHandler(w http.ResponseWriter, r *http.Request) {
	mu.RLock()
	count := len(sessions)
	mu.RUnlock()
	w.Write([]byte("cidebug relay running. Active sessions: " +
		string(rune('0'+count)) + "\n"))
}

func main() {
	http.HandleFunc("/runner", runnerHandler)
	http.HandleFunc("/developer", developerHandler)
	http.HandleFunc("/status", statusHandler)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Printf("cidebug relay server starting on :%s", port)
	log.Printf("Runner endpoint:    ws://localhost:%s/runner", port)
	log.Printf("Developer endpoint: ws://localhost:%s/developer?token=TOKEN", port)
	log.Printf("Status:             http://localhost:%s/status", port)

	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal("Server error:", err)
	}
}