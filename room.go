package fresque

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"slices"
	"sync"
	"time"
)

var (
	errReadOnly        = errors.New("read-only access")
	errDuplicate       = errors.New("element edited twice in one operation")
	errElementTooLarge = errors.New("element too large")
	errBoardFull       = errors.New("board size limit reached")
	errTooManyElements = errors.New("board element limit reached")
)

type room struct {
	hub   *Hub
	key   string
	ready chan struct{}
	err   error
	refs  int

	mu       sync.Mutex
	elements map[string][]byte
	size     int
	peers    map[uint32]*peer
	nextSID  uint32
	acks     map[string]uint64
	version  uint64
	saved    uint64
	saveErr  string

	saveMu   sync.Mutex
	kick     chan struct{}
	done     chan struct{}
	stopOnce sync.Once
}

func newRoom(h *Hub, key string) *room {
	return &room{
		hub:   h,
		key:   key,
		ready: make(chan struct{}),
		peers: map[uint32]*peer{},
		acks:  map[string]uint64{},
		kick:  make(chan struct{}, 1),
		done:  make(chan struct{}),
	}
}

func (r *room) load() {
	defer close(r.ready)
	data, err := r.hub.store.Load(context.Background(), r.key)
	if err == nil {
		r.elements, r.size, err = decodeBoard(data)
	}
	if err != nil {
		r.err = err
		r.hub.forget(r)
		return
	}
	go r.saveLoop()
}

func (r *room) stop() {
	r.stopOnce.Do(func() { close(r.done) })
}

func (r *room) join(p *peer) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.nextSID++
	p.sid = r.nextSID

	peers := make([]peerView, 0, len(r.peers))
	for _, q := range r.peers {
		peers = append(peers, q.view())
	}
	slices.SortFunc(peers, func(a, b peerView) int { return cmp.Compare(a.SID, b.SID) })
	elements := make([][]byte, 0, len(r.elements))
	for _, e := range r.elements {
		elements = append(elements, e)
	}
	p.send(helloFrame(hello{
		SID:      p.sid,
		Ack:      r.acks[p.info.Client],
		Version:  r.version,
		Saved:    r.saved,
		ReadOnly: p.info.ReadOnly,
		Error:    r.saveErr,
		Peers:    peers,
	}, elements))

	r.broadcast(joinFrame(p.view()), nil)
	r.peers[p.sid] = p
}

func (r *room) leave(p *peer) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.peers, p.sid)
	r.broadcast(leaveFrame(p.sid), nil)
}

func (r *room) closePeers(code int, reason string) []*peer {
	r.mu.Lock()
	defer r.mu.Unlock()
	peers := make([]*peer, 0, len(r.peers))
	for _, p := range r.peers {
		p.close(code, reason)
		peers = append(peers, p)
	}
	return peers
}

// broadcast sends to every peer but except. Callers hold r.mu.
func (r *room) broadcast(frame []byte, except *peer) {
	for _, p := range r.peers {
		if p != except {
			p.send(frame)
		}
	}
}

func (r *room) handle(p *peer, msg []byte) {
	if d, ok := presenceData(msg); ok {
		r.relayPresence(p, d)
		return
	}
	var in inbound
	if err := json.Unmarshal(msg, &in); err != nil {
		if in.T == "op" {
			p.send(messageFrame("nack", in.N, "malformed operation"))
		}
		return
	}
	switch in.T {
	case "op":
		r.apply(p, &in)
	case "eph":
		r.relayPresence(p, in.D)
	}
}

func (r *room) relayPresence(p *peer, d []byte) {
	if len(d) == 0 || len(d) > maxPresenceBytes || !p.allowPresence(time.Now()) {
		return
	}
	r.mu.Lock()
	r.broadcast(presenceFrame(p.sid, d), p)
	r.mu.Unlock()
}

func (r *room) apply(p *peer, in *inbound) {
	r.mu.Lock()
	defer r.mu.Unlock()
	client := p.info.Client
	if client != "" && in.N != 0 && in.N <= r.acks[client] {
		p.send(ackFrame(in.N, r.version))
		return
	}
	if err := r.check(p, in); err != nil {
		p.send(messageFrame("nack", in.N, err.Error()))
		return
	}
	for _, e := range in.Put {
		r.size += len(e.raw) - len(r.elements[e.id])
		r.elements[e.id] = e.raw
	}
	for _, id := range in.Del {
		r.size -= len(r.elements[string(id)])
		delete(r.elements, string(id))
	}
	if client != "" {
		r.acks[client] = in.N
	}
	r.version++
	r.broadcast(opFrame(p.sid, in.Put, in.Del), p)
	p.send(ackFrame(in.N, r.version))
	r.requestSave()
}

// check validates an operation as a whole: it is applied entirely or not at
// all. Limits only refuse what grows the board, so an oversized board can
// still be cleaned up.
func (r *room) check(p *peer, in *inbound) error {
	if p.info.ReadOnly {
		return errReadOnly
	}
	opt := r.hub.opt
	seen := make(map[string]struct{}, len(in.Put)+len(in.Del))
	size, count := r.size, len(r.elements)
	for _, e := range in.Put {
		if _, dup := seen[e.id]; dup {
			return errDuplicate
		}
		seen[e.id] = struct{}{}
		if len(e.raw) > opt.MaxElementBytes {
			return errElementTooLarge
		}
		old, exists := r.elements[e.id]
		size += len(e.raw) - len(old)
		if !exists {
			count++
		}
	}
	for _, id := range in.Del {
		if _, dup := seen[string(id)]; dup {
			return errDuplicate
		}
		seen[string(id)] = struct{}{}
		if old, exists := r.elements[string(id)]; exists {
			size -= len(old)
			count--
		}
	}
	if size > r.size && size > opt.MaxBoardBytes {
		return errBoardFull
	}
	if count > len(r.elements) && count > opt.MaxElements {
		return errTooManyElements
	}
	return nil
}

func (r *room) requestSave() {
	select {
	case r.kick <- struct{}{}:
	default:
	}
}

func (r *room) dirty() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.version != r.saved
}

// saveLoop saves once edits pause for SaveDelay, or SaveMaxDelay after the
// first unsaved one, whichever comes first.
func (r *room) saveLoop() {
	opt := r.hub.opt
	for {
		select {
		case <-r.kick:
		case <-r.done:
			return
		}
		deadline := time.Now().Add(opt.SaveMaxDelay)
		timer := time.NewTimer(opt.SaveDelay)
	wait:
		for {
			select {
			case <-r.kick:
				timer.Reset(min(opt.SaveDelay, time.Until(deadline)))
			case <-timer.C:
				break wait
			case <-r.done:
				timer.Stop()
				return
			}
		}
		if err := r.flush(context.Background()); err != nil && !errors.Is(err, ErrGone) {
			time.AfterFunc(opt.SaveMaxDelay, r.requestSave)
			continue
		}
		r.hub.unloadIfIdle(r)
	}
}

// flush saves the board if it changed since the last save, and tells every
// peer how it went.
func (r *room) flush(ctx context.Context) error {
	r.saveMu.Lock()
	defer r.saveMu.Unlock()

	r.mu.Lock()
	if r.version == r.saved {
		r.mu.Unlock()
		return nil
	}
	version := r.version
	elements := make([]element, 0, len(r.elements))
	for id, raw := range r.elements {
		elements = append(elements, element{id: id, raw: raw})
	}
	r.mu.Unlock()

	err := r.hub.store.Save(ctx, r.key, encodeBoard(elements))

	r.mu.Lock()
	defer r.mu.Unlock()
	if errors.Is(err, ErrGone) {
		r.saved = r.version
		for _, p := range r.peers {
			p.close(CloseRevoked, err.Error())
		}
		return err
	}
	if err != nil {
		r.saveErr = err.Error()
		r.broadcast(messageFrame("error", 0, r.saveErr), nil)
		return err
	}
	r.saved, r.saveErr = version, ""
	r.broadcast(savedFrame(version), nil)
	return nil
}
