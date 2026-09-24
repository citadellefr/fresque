package fresque

import (
	"sync"
	"time"
)

const (
	outboxSize   = 512
	writeWait    = 10 * time.Second
	pingInterval = 25 * time.Second
	pongWait     = 60 * time.Second
)

type peer struct {
	conn Conn
	info Peer
	sid  uint32

	out      chan []byte
	done     chan struct{}
	finished chan struct{}
	once     sync.Once
	code     int
	reason   string

	rate   float64
	tokens float64
	refill time.Time
}

func newPeer(conn Conn, info Peer, rate int) *peer {
	return &peer{
		conn:     conn,
		info:     info,
		out:      make(chan []byte, outboxSize),
		done:     make(chan struct{}),
		finished: make(chan struct{}),
		rate:     float64(rate),
		tokens:   float64(rate),
		refill:   time.Now(),
	}
}

func (p *peer) view() peerView {
	return peerView{SID: p.sid, ID: p.info.ID, Name: p.info.Name, ReadOnly: p.info.ReadOnly}
}

// send never blocks: a peer that cannot keep up is disconnected, and catches
// up from the board it is sent when it reconnects.
func (p *peer) send(frame []byte) {
	select {
	case p.out <- frame:
	default:
		p.close(CloseTooSlow, "connection too slow")
	}
}

// close ends the connection, with a close frame when code is not zero.
func (p *peer) close(code int, reason string) {
	p.once.Do(func() {
		p.code, p.reason = code, reason
		close(p.done)
	})
}

func (p *peer) writeLoop() {
	defer close(p.finished)
	defer p.conn.Close()
	ping := time.NewTicker(pingInterval)
	defer ping.Stop()
	for {
		select {
		case frame := <-p.out:
			_ = p.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if p.conn.WriteMessage(textMessage, frame) != nil {
				p.close(0, "")
				return
			}
		case <-ping.C:
			if p.conn.WriteControl(pingMessage, nil, time.Now().Add(writeWait)) != nil {
				p.close(0, "")
				return
			}
		case <-p.done:
			if p.code != 0 {
				_ = p.conn.WriteControl(closeMessage, closePayload(p.code, p.reason), time.Now().Add(time.Second))
			}
			return
		}
	}
}

func (p *peer) readLoop(limit int64, handle func([]byte)) {
	p.conn.SetReadLimit(limit)
	_ = p.conn.SetReadDeadline(time.Now().Add(pongWait))
	p.conn.SetPongHandler(func(string) error {
		return p.conn.SetReadDeadline(time.Now().Add(pongWait))
	})
	for {
		kind, msg, err := p.conn.ReadMessage()
		if err != nil {
			return
		}
		if kind == textMessage {
			handle(msg)
		}
	}
}

// allowPresence is a token bucket: only the read loop calls it.
func (p *peer) allowPresence(now time.Time) bool {
	p.tokens = min(p.rate, p.tokens+now.Sub(p.refill).Seconds()*p.rate)
	p.refill = now
	if p.tokens < 1 {
		return false
	}
	p.tokens--
	return true
}
