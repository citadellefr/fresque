package fresque

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"slices"
	"sync"
	"time"
)

// Hub serves any number of boards. Each board is loaded when its first peer
// connects and leaves memory once the last one is gone and it is saved.
type Hub struct {
	store  Store
	opt    Options
	mu     sync.Mutex
	rooms  map[string]*room
	closed bool
}

func NewHub(store Store, opt Options) *Hub {
	return &Hub{
		store: store,
		opt:   opt.withDefaults(),
		rooms: map[string]*room{},
	}
}

// Serve runs one connection to a board until it ends. The caller has already
// authenticated and authorized it. Cancelling ctx disconnects the peer with
// CloseRevoked and the context's cause as the reason.
//
// The returned error is only about opening the board; a connection that
// simply ends returns nil.
func (h *Hub) Serve(ctx context.Context, conn Conn, board string, info Peer) error {
	r, err := h.acquire(ctx, board)
	if err != nil {
		_ = conn.WriteControl(closeMessage, closePayload(CloseLoadFailed, err.Error()), time.Now().Add(time.Second))
		_ = conn.Close()
		return err
	}
	defer h.release(r)

	p := newPeer(conn, info, h.opt.PresenceRate)
	r.join(p)
	go p.writeLoop()
	stop := context.AfterFunc(ctx, func() {
		p.close(CloseRevoked, reasonOf(ctx))
	})
	p.readLoop(h.opt.MaxMessageBytes, func(msg []byte) { r.handle(p, msg) })
	stop()
	r.leave(p)
	p.close(0, "")
	<-p.finished
	return nil
}

// Disconnect ends every connection to a board, e.g. when the file behind it
// is deleted or moved.
func (h *Hub) Disconnect(board, reason string) {
	h.mu.Lock()
	r := h.rooms[board]
	h.mu.Unlock()
	if r != nil {
		r.closePeers(CloseRevoked, reason)
	}
}

// Close disconnects everyone and saves every board with unsaved edits.
func (h *Hub) Close(ctx context.Context) error {
	h.mu.Lock()
	h.closed = true
	rooms := slices.Collect(maps.Values(h.rooms))
	h.mu.Unlock()

	var errs []error
	for _, r := range rooms {
		<-r.ready
		if r.err != nil {
			continue
		}
		for _, p := range r.closePeers(CloseShutdown, "server shutting down") {
			select {
			case <-p.finished:
			case <-ctx.Done():
			}
		}
		if err := r.flush(ctx); err != nil {
			errs = append(errs, fmt.Errorf("fresque: saving %s: %w", r.key, err))
		}
		r.stop()
	}
	return errors.Join(errs...)
}

func (h *Hub) acquire(ctx context.Context, key string) (*room, error) {
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return nil, ErrClosed
	}
	r := h.rooms[key]
	if r == nil {
		r = newRoom(h, key)
		h.rooms[key] = r
		go r.load()
	}
	r.refs++
	h.mu.Unlock()

	select {
	case <-r.ready:
	case <-ctx.Done():
		h.release(r)
		return nil, context.Cause(ctx)
	}
	if r.err != nil {
		h.release(r)
		return nil, r.err
	}
	return r, nil
}

func (h *Hub) release(r *room) {
	h.mu.Lock()
	r.refs--
	idle := r.refs == 0 && h.rooms[r.key] == r
	h.mu.Unlock()
	if !idle {
		return
	}
	if err := r.flush(context.Background()); err != nil && !errors.Is(err, ErrGone) {
		r.requestSave()
		return
	}
	h.unloadIfIdle(r)
}

// unloadIfIdle drops a board nobody is connected to once it is saved. A board
// whose save failed stays in memory until a retry succeeds.
func (h *Hub) unloadIfIdle(r *room) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if r.refs == 0 && h.rooms[r.key] == r && !r.dirty() {
		delete(h.rooms, r.key)
		r.stop()
	}
}

func (h *Hub) forget(r *room) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.rooms[r.key] == r {
		delete(h.rooms, r.key)
	}
}

func reasonOf(ctx context.Context) string {
	if cause := context.Cause(ctx); cause != nil && !errors.Is(cause, context.Canceled) {
		return cause.Error()
	}
	return "access revoked"
}
