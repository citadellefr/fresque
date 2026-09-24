// Package fresque is the server half of a collaborative whiteboard. It keeps
// every open board in memory, orders the edits of the people connected to it,
// relays their cursors and saves the board through a Store.
//
// A board is a set of elements: JSON objects of which the server only reads
// the "id". An edit replaces or deletes whole elements, and the order in which
// the hub receives edits is the order every client applies them in, so all of
// them converge on the same board without any merge logic.
package fresque

import (
	"context"
	"errors"
	"time"
)

// Conn is the part of a WebSocket connection the hub uses. The Conn types of
// github.com/gorilla/websocket and github.com/fasthttp/websocket satisfy it.
type Conn interface {
	ReadMessage() (messageType int, p []byte, err error)
	WriteMessage(messageType int, data []byte) error
	WriteControl(messageType int, data []byte, deadline time.Time) error
	SetReadLimit(limit int64)
	SetReadDeadline(t time.Time) error
	SetWriteDeadline(t time.Time) error
	SetPongHandler(h func(appData string) error)
	Close() error
}

// Store persists boards. Load returns empty data and no error for a board
// that was never saved.
type Store interface {
	Load(ctx context.Context, board string) ([]byte, error)
	Save(ctx context.Context, board string, data []byte) error
}

// Peer describes the person behind a connection.
type Peer struct {
	ID   string
	Name string
	// Client names the application instance across reconnections, so that
	// the edits it sends again after a drop are not applied twice.
	Client   string
	ReadOnly bool
}

// Options tunes a Hub. Zero fields take the defaults.
type Options struct {
	// SaveDelay is the quiet time after an edit before the board is saved.
	SaveDelay time.Duration
	// SaveMaxDelay bounds how long an edit stays unsaved while edits keep
	// coming, and spaces the retries of a failed save.
	SaveMaxDelay    time.Duration
	MaxElements     int
	MaxElementBytes int
	MaxBoardBytes   int
	MaxMessageBytes int64
	// PresenceRate is how many cursor frames a peer may send per second.
	PresenceRate int
}

// Close codes sent to a client whose connection the hub ends.
const (
	CloseLoadFailed = 4000
	CloseRevoked    = 4001
	CloseTooSlow    = 4002
	CloseShutdown   = 4003
)

var ErrClosed = errors.New("fresque: hub closed")

// ErrGone is returned (possibly wrapped) by Store.Save when the board no
// longer exists, e.g. its file was deleted: everyone connected to it is
// disconnected with the error as the reason, and its unsaved edits dropped.
var ErrGone = errors.New("fresque: board no longer exists")

func (o Options) withDefaults() Options {
	if o.SaveDelay <= 0 {
		o.SaveDelay = 2 * time.Second
	}
	if o.SaveMaxDelay <= 0 {
		o.SaveMaxDelay = 10 * time.Second
	}
	if o.MaxElements <= 0 {
		o.MaxElements = 50_000
	}
	if o.MaxElementBytes <= 0 {
		o.MaxElementBytes = 256 << 10
	}
	if o.MaxBoardBytes <= 0 {
		o.MaxBoardBytes = 32 << 20
	}
	if o.MaxMessageBytes <= 0 {
		o.MaxMessageBytes = 2 << 20
	}
	if o.PresenceRate <= 0 {
		o.PresenceRate = 40
	}
	return o
}
