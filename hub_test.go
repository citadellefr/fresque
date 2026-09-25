package fresque

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf8"
)

type fakeConn struct {
	in        chan []byte
	out       chan []byte
	closed    chan struct{}
	closeOnce sync.Once

	mu          sync.Mutex
	closeCode   int
	closeReason string
}

func newFakeConn() *fakeConn {
	return &fakeConn{
		in:     make(chan []byte, 64),
		out:    make(chan []byte, 1024),
		closed: make(chan struct{}),
	}
}

var errConnClosed = errors.New("closed")

func (c *fakeConn) ReadMessage() (int, []byte, error) {
	select {
	case m := <-c.in:
		return textMessage, m, nil
	case <-c.closed:
		return 0, nil, errConnClosed
	}
}

func (c *fakeConn) WriteMessage(_ int, data []byte) error {
	select {
	case <-c.closed:
		return errConnClosed
	case c.out <- data:
		return nil
	}
}

func (c *fakeConn) WriteControl(kind int, data []byte, _ time.Time) error {
	if kind == closeMessage && len(data) >= 2 {
		c.mu.Lock()
		c.closeCode, c.closeReason = int(data[0])<<8|int(data[1]), string(data[2:])
		c.mu.Unlock()
	}
	return nil
}

func (c *fakeConn) SetReadLimit(int64)                        {}
func (c *fakeConn) SetReadDeadline(time.Time) error           { return nil }
func (c *fakeConn) SetWriteDeadline(time.Time) error          { return nil }
func (c *fakeConn) SetPongHandler(func(appData string) error) {}

func (c *fakeConn) Close() error {
	c.closeOnce.Do(func() { close(c.closed) })
	return nil
}

func (c *fakeConn) closeFrame() (int, string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.closeCode, c.closeReason
}

type memStore struct {
	mu    sync.Mutex
	data  map[string][]byte
	saves chan string
	fail  error
}

func newMemStore() *memStore {
	return &memStore{data: map[string][]byte{}, saves: make(chan string, 64)}
}

func (s *memStore) Load(_ context.Context, board string) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.fail != nil {
		return nil, s.fail
	}
	return s.data[board], nil
}

func (s *memStore) Save(_ context.Context, board string, data []byte) error {
	s.mu.Lock()
	err := s.fail
	if err == nil {
		s.data[board] = data
	}
	s.mu.Unlock()
	s.saves <- board
	return err
}

func (s *memStore) setFail(err error) {
	s.mu.Lock()
	s.fail = err
	s.mu.Unlock()
}

func (s *memStore) board(key string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return string(s.data[key])
}

type frame struct {
	T        string            `json:"t"`
	SID      uint32            `json:"sid"`
	N        uint64            `json:"n"`
	V        uint64            `json:"v"`
	Ack      uint64            `json:"ack"`
	Error    string            `json:"error"`
	Put      []json.RawMessage `json:"put"`
	Del      []string          `json:"del"`
	D        json.RawMessage   `json:"d"`
	Elements []json.RawMessage `json:"elements"`
	Peers    []peerView        `json:"peers"`
	Peer     peerView          `json:"peer"`
}

type client struct {
	t    *testing.T
	conn *fakeConn
	done chan error
}

func connect(t *testing.T, h *Hub, ctx context.Context, board string, info Peer) *client {
	t.Helper()
	c := &client{t: t, conn: newFakeConn(), done: make(chan error, 1)}
	go func() { c.done <- h.Serve(ctx, c.conn, board, info) }()
	t.Cleanup(func() { c.conn.Close() })
	return c
}

func (c *client) send(s string) { c.conn.in <- []byte(s) }

func (c *client) next() frame {
	c.t.Helper()
	select {
	case raw := <-c.conn.out:
		var f frame
		if err := json.Unmarshal(raw, &f); err != nil {
			c.t.Fatalf("invalid frame %s: %v", raw, err)
		}
		return f
	case <-time.After(2 * time.Second):
		c.t.Fatal("no frame")
		return frame{}
	}
}

func (c *client) expect(kind string) frame {
	c.t.Helper()
	f := c.next()
	if f.T != kind {
		c.t.Fatalf("got %q frame, want %q: %+v", f.T, kind, f)
	}
	return f
}

func (c *client) quiet() {
	c.t.Helper()
	select {
	case raw := <-c.conn.out:
		c.t.Fatalf("unexpected frame %s", raw)
	case <-time.After(50 * time.Millisecond):
	}
}

func (c *client) leave() {
	c.t.Helper()
	c.conn.Close()
	select {
	case <-c.done:
	case <-time.After(2 * time.Second):
		c.t.Fatal("Serve did not return")
	}
}

func fastOptions() Options {
	return Options{SaveDelay: 20 * time.Millisecond, SaveMaxDelay: 100 * time.Millisecond}
}

func TestEditsReachOthersAndAreSaved(t *testing.T) {
	store := newMemStore()
	h := NewHub(store, fastOptions())
	ctx := context.Background()

	alice := connect(t, h, ctx, "b", Peer{ID: "1", Name: "Alice", Client: "ca"})
	if f := alice.expect("hello"); f.SID != 1 || len(f.Elements) != 0 || len(f.Peers) != 0 {
		t.Fatalf("hello = %+v", f)
	}
	bob := connect(t, h, ctx, "b", Peer{ID: "2", Name: "Bob"})
	if f := bob.expect("hello"); len(f.Peers) != 1 || f.Peers[0].Name != "Alice" {
		t.Fatalf("hello = %+v", f)
	}
	if f := alice.expect("join"); f.Peer.Name != "Bob" || f.Peer.SID != 2 {
		t.Fatalf("join = %+v", f)
	}

	alice.send(`{"t":"op","n":1,"put":[{"id":"e1","k":"r","x":1}]}`)
	if f := alice.expect("ack"); f.N != 1 || f.V != 1 {
		t.Fatalf("ack = %+v", f)
	}
	f := bob.expect("op")
	if f.SID != 1 || len(f.Put) != 1 || string(f.Put[0]) != `{"id":"e1","k":"r","x":1}` {
		t.Fatalf("op = %+v", f)
	}

	<-store.saves
	if got := store.board("b"); !strings.Contains(got, `{"id":"e1","k":"r","x":1}`) {
		t.Fatalf("saved %q", got)
	}
	if f := alice.expect("saved"); f.V != 1 {
		t.Fatalf("saved = %+v", f)
	}
	bob.expect("saved")

	bob.send(`{"t":"op","n":1,"del":["e1"]}`)
	bob.expect("ack")
	if f := alice.expect("op"); len(f.Del) != 1 || f.Del[0] != "e1" || f.SID != 2 {
		t.Fatalf("op = %+v", f)
	}

	bob.leave()
	alice.expect("leave")
}

func TestHelloCarriesBoardAndResumePoint(t *testing.T) {
	store := newMemStore()
	store.data["b"] = []byte(`{"fresque":1,"elements":[{"id":"a"},{"id":"b"}]}`)
	h := NewHub(store, fastOptions())
	ctx := context.Background()

	keeper := connect(t, h, ctx, "b", Peer{ID: "0"})
	keeper.expect("hello")

	first := connect(t, h, ctx, "b", Peer{ID: "1", Client: "c1"})
	if f := first.expect("hello"); len(f.Elements) != 2 || f.Ack != 0 {
		t.Fatalf("hello = %+v", f)
	}
	first.send(`{"t":"op","n":5,"put":[{"id":"c"}]}`)
	first.expect("ack")
	first.leave()

	again := connect(t, h, ctx, "b", Peer{ID: "1", Client: "c1"})
	if f := again.expect("hello"); len(f.Elements) != 3 || f.Ack != 5 {
		t.Fatalf("hello = %+v", f)
	}
	again.send(`{"t":"op","n":5,"put":[{"id":"stale"}]}`)
	if f := again.expect("ack"); f.N != 5 {
		t.Fatalf("ack = %+v", f)
	}
	ops := 0
	for {
		select {
		case raw := <-keeper.conn.out:
			if strings.Contains(string(raw), `"t":"op"`) {
				ops++
			}
			continue
		case <-time.After(100 * time.Millisecond):
		}
		break
	}
	if ops != 1 {
		t.Fatalf("keeper saw %d operations, want 1", ops)
	}
}

func TestRefusedOperations(t *testing.T) {
	h := NewHub(newMemStore(), Options{MaxElementBytes: 64, MaxElements: 2})
	ctx := context.Background()

	reader := connect(t, h, ctx, "b", Peer{ID: "1", ReadOnly: true})
	reader.expect("hello")
	reader.send(`{"t":"op","n":1,"put":[{"id":"a"}]}`)
	if f := reader.expect("nack"); f.N != 1 || f.Error != errReadOnly.Error() {
		t.Fatalf("nack = %+v", f)
	}

	writer := connect(t, h, ctx, "b", Peer{ID: "2"})
	writer.expect("hello")
	reader.expect("join")

	cases := []struct{ op, err string }{
		{`{"t":"op","n":1,"put":[{"id":"a"},{"id":"a"}]}`, errDuplicate.Error()},
		{`{"t":"op","n":2,"put":[{"id":"a"}],"del":["a"]}`, errDuplicate.Error()},
		{`{"t":"op","n":3,"put":[{"id":"a","pad":"` + strings.Repeat("x", 64) + `"}]}`, errElementTooLarge.Error()},
		{`{"t":"op","n":4,"put":[{"id":"a"},{"id":"b"},{"id":"c"}]}`, errTooManyElements.Error()},
		{`{"t":"op","n":5,"put":[{"id":"bad id"}]}`, "malformed operation"},
		{`{"t":"op","n":6,"put":[[1]]}`, "malformed operation"},
	}
	for _, c := range cases {
		writer.send(c.op)
		if f := writer.expect("nack"); f.Error != c.err {
			t.Errorf("%s: nack %q, want %q", c.op, f.Error, c.err)
		}
	}
	reader.quiet()

	writer.send(`{"t":"op","n":7,"put":[{"id":"a"},{"id":"b"}]}`)
	writer.expect("ack")
	writer.send(`{"t":"op","n":8,"put":[{"id":"c"}],"del":["a"]}`)
	writer.expect("ack")
}

func TestPresenceIsRelayedAndRateLimited(t *testing.T) {
	h := NewHub(newMemStore(), Options{PresenceRate: 3})
	ctx := context.Background()
	a := connect(t, h, ctx, "b", Peer{ID: "1"})
	a.expect("hello")
	b := connect(t, h, ctx, "b", Peer{ID: "2"})
	b.expect("hello")
	a.expect("join")

	for range 10 {
		a.send(`{"t":"eph","d":{"c":[1,2]}}`)
	}
	for range 3 {
		if f := b.expect("eph"); f.SID != 1 || string(f.D) != `{"c":[1,2]}` {
			t.Fatalf("eph = %+v", f)
		}
	}
	b.quiet()
	a.quiet()
}

func FuzzReadID(f *testing.F) {
	for _, seed := range []string{
		`{"id":"a1"}`,
		` { "k" : "s" , "p" : [1, 2.5e3, -0] , "id" : "b_2-" } `,
		`{"n":{"id":"x"},"tx":"\\\"id\":","id":"c"}`,
		`{"id":"a","id":"b"}`,
		`{"ID":"a"}`,
		`{"id":"\u0061"}`,
		`{"id":1}`,
		`[{"id":"a"}]`,
	} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, s string) {
		if !json.Valid([]byte(s)) {
			return
		}
		id, ok := readID([]byte(s))
		var members map[string]json.RawMessage
		var want string
		wantOK := json.Unmarshal([]byte(s), &members) == nil &&
			json.Unmarshal(members["id"], &want) == nil && validID(want) &&
			string(members["id"]) == `"`+want+`"`
		twice := strings.Count(s, `"id"`) > 1
		if ok != wantOK && !(twice && !ok) || ok && id != want {
			t.Fatalf("readID(%s) = %q, %v; want %q, %v", s, id, ok, want, wantOK)
		}
	})
}

func TestPresenceData(t *testing.T) {
	for _, c := range []struct {
		msg, d string
		ok     bool
	}{
		{`{"t":"eph","d":{"c":[1,2]}}`, `{"c":[1,2]}`, true},
		{`{"t":"eph","d":null}`, `null`, true},
		{`{"t":"eph","d":{"c":[1,2]},"x":1}`, "", false},
		{`{"t":"eph","d":{"c":[1,2}}`, "", false},
		{`{"d":{"c":[1,2]},"t":"eph"}`, "", false},
		{`{"t":"op","n":1}`, "", false},
	} {
		d, ok := presenceData([]byte(c.msg))
		if ok != c.ok || ok && string(d) != c.d {
			t.Errorf("presenceData(%s) = %s, %v", c.msg, d, ok)
		}
	}
}

func TestPresenceInAnyKeyOrderIsRelayed(t *testing.T) {
	h := NewHub(newMemStore(), Options{})
	ctx := context.Background()
	a := connect(t, h, ctx, "b", Peer{ID: "1"})
	a.expect("hello")
	b := connect(t, h, ctx, "b", Peer{ID: "2"})
	b.expect("hello")
	a.expect("join")

	a.send(`{"d":{"c":[3,4]},"t":"eph"}`)
	if f := b.expect("eph"); string(f.D) != `{"c":[3,4]}` {
		t.Fatalf("eph = %+v", f)
	}
}

type compressingConn struct {
	*fakeConn
	sizes chan int
	next  bool
}

func (c *compressingConn) EnableWriteCompression(enable bool) { c.next = enable }

func (c *compressingConn) WriteMessage(kind int, data []byte) error {
	if c.next {
		c.sizes <- len(data)
	}
	return c.fakeConn.WriteMessage(kind, data)
}

func TestOnlyLargeFramesAreCompressed(t *testing.T) {
	h := NewHub(newMemStore(), Options{})
	ctx := context.Background()
	a := connect(t, h, ctx, "b", Peer{ID: "1"})
	a.expect("hello")
	conn := &compressingConn{fakeConn: newFakeConn(), sizes: make(chan int, 8)}
	go func() { _ = h.Serve(ctx, conn, "b", Peer{ID: "2"}) }()
	t.Cleanup(func() { conn.Close() })
	<-conn.out
	a.expect("join")

	a.send(`{"t":"op","n":1,"put":[{"id":"small"}]}`)
	a.send(`{"t":"op","n":2,"put":[{"id":"large","tx":"` + strings.Repeat("x", compressFrom) + `"}]}`)
	<-conn.out
	<-conn.out
	select {
	case size := <-conn.sizes:
		if size < compressFrom {
			t.Fatalf("compressed a %d-byte frame", size)
		}
	default:
		t.Fatal("large frame not compressed")
	}
	if len(conn.sizes) != 0 {
		t.Fatal("small frame compressed")
	}
}

func TestSaveFailureIsReportedAndRetried(t *testing.T) {
	store := newMemStore()
	h := NewHub(store, fastOptions())
	a := connect(t, h, context.Background(), "b", Peer{ID: "1"})
	a.expect("hello")

	store.setFail(errors.New("disk full"))
	a.send(`{"t":"op","n":1,"put":[{"id":"a"}]}`)
	a.expect("ack")
	<-store.saves
	if f := a.expect("error"); f.Error != "disk full" {
		t.Fatalf("error = %+v", f)
	}

	late := connect(t, h, context.Background(), "b", Peer{ID: "2"})
	if f := late.expect("hello"); f.Error != "disk full" {
		t.Fatalf("hello = %+v", f)
	}
	a.expect("join")

	store.setFail(nil)
	<-store.saves
	for _, c := range []*client{a, late} {
		if f := c.expect("saved"); f.V != 1 {
			t.Fatalf("saved = %+v", f)
		}
	}
}

func TestLastLeaveSavesAndUnloads(t *testing.T) {
	store := newMemStore()
	h := NewHub(store, Options{SaveDelay: time.Hour, SaveMaxDelay: time.Hour})
	a := connect(t, h, context.Background(), "b", Peer{ID: "1"})
	a.expect("hello")
	a.send(`{"t":"op","n":1,"put":[{"id":"a"}]}`)
	a.expect("ack")
	a.leave()

	if !strings.Contains(store.board("b"), `{"id":"a"}`) {
		t.Fatalf("board not saved: %q", store.board("b"))
	}
	h.mu.Lock()
	loaded := len(h.rooms)
	h.mu.Unlock()
	if loaded != 0 {
		t.Fatalf("%d boards still loaded", loaded)
	}
}

func TestLoadFailureClosesConnection(t *testing.T) {
	store := newMemStore()
	store.setFail(errors.New("file not found"))
	h := NewHub(store, Options{})
	c := connect(t, h, context.Background(), "b", Peer{ID: "1"})
	if err := <-c.done; err == nil || err.Error() != "file not found" {
		t.Fatalf("Serve = %v", err)
	}
	if code, reason := c.conn.closeFrame(); code != CloseLoadFailed || reason != "file not found" {
		t.Fatalf("close %d %q", code, reason)
	}

	store.setFail(nil)
	again := connect(t, h, context.Background(), "b", Peer{ID: "1"})
	again.expect("hello")
}

func TestCancelledContextRevokes(t *testing.T) {
	h := NewHub(newMemStore(), Options{})
	ctx, cancel := context.WithCancelCause(context.Background())
	c := connect(t, h, ctx, "b", Peer{ID: "1"})
	c.expect("hello")
	cancel(errors.New("share removed"))
	select {
	case <-c.done:
	case <-time.After(2 * time.Second):
		t.Fatal("Serve did not return")
	}
	if code, reason := c.conn.closeFrame(); code != CloseRevoked || reason != "share removed" {
		t.Fatalf("close %d %q", code, reason)
	}
}

func TestCloseSavesEverything(t *testing.T) {
	store := newMemStore()
	h := NewHub(store, Options{SaveDelay: time.Hour, SaveMaxDelay: time.Hour})
	a := connect(t, h, context.Background(), "b", Peer{ID: "1"})
	a.expect("hello")
	a.send(`{"t":"op","n":1,"put":[{"id":"a"}]}`)
	a.expect("ack")

	if err := h.Close(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(store.board("b"), `{"id":"a"}`) {
		t.Fatalf("board not saved: %q", store.board("b"))
	}
	if code, _ := a.conn.closeFrame(); code != CloseShutdown {
		t.Fatalf("close code %d", code)
	}
	late := connect(t, h, context.Background(), "b", Peer{ID: "2"})
	if err := <-late.done; !errors.Is(err, ErrClosed) {
		t.Fatalf("Serve after Close = %v", err)
	}
}

func TestBoardFileRoundTrip(t *testing.T) {
	data := encodeBoard([]element{{"b", []byte(`{"id":"b"}`)}, {"a", []byte(`{"id":"a","x":1}`)}})
	want := "{\"fresque\":1,\"elements\":[\n{\"id\":\"a\",\"x\":1},\n{\"id\":\"b\"}\n]}\n"
	if string(data) != want {
		t.Fatalf("encoded %q", data)
	}
	elements, size, err := decodeBoard(data)
	if err != nil || len(elements) != 2 || size != len(`{"id":"b"}`)+len(`{"id":"a","x":1}`) {
		t.Fatalf("decoded %v %d %v", elements, size, err)
	}
	if _, _, err := decodeBoard([]byte(`{"fresque":2,"elements":[]}`)); err == nil {
		t.Fatal("future format accepted")
	}
	if elements, _, err := decodeBoard(nil); err != nil || len(elements) != 0 {
		t.Fatal("empty file refused")
	}
}

func TestClosePayloadTruncatesOnRuneBoundary(t *testing.T) {
	p := closePayload(CloseRevoked, strings.Repeat("é", 100))
	if len(p) > 125 || !strings.HasPrefix(string(p[2:]), "é") || !utf8.ValidString(string(p[2:])) {
		t.Fatalf("payload %q", p)
	}
}

func TestGoneBoardDisconnectsAndUnloads(t *testing.T) {
	store := newMemStore()
	h := NewHub(store, fastOptions())
	a := connect(t, h, context.Background(), "b", Peer{ID: "1"})
	a.expect("hello")

	store.setFail(fmt.Errorf("file deleted: %w", ErrGone))
	a.send(`{"t":"op","n":1,"put":[{"id":"a"}]}`)
	a.expect("ack")
	select {
	case <-a.done:
	case <-time.After(2 * time.Second):
		t.Fatal("Serve did not return")
	}
	if code, reason := a.conn.closeFrame(); code != CloseRevoked || !strings.HasPrefix(reason, "file deleted") {
		t.Fatalf("close %d %q", code, reason)
	}
	h.mu.Lock()
	loaded := len(h.rooms)
	h.mu.Unlock()
	if loaded != 0 {
		t.Fatalf("%d boards still loaded", loaded)
	}
}
