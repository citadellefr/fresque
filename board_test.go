package fresque

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/citadellefr/trame"
	"github.com/citadellefr/trame/trametest"
)

var fast = Options{Options: trame.Options{SaveDelay: 20 * time.Millisecond, SaveMaxDelay: 100 * time.Millisecond}}

func join(t *testing.T, h *trame.Hub, key string, info trame.Peer) (*trametest.Client, trametest.Frame, trametest.Frame) {
	t.Helper()
	return trametest.Join(t, func(c *trametest.Conn) error { return h.Serve(context.Background(), c, key, info) })
}

// expect is the next frame of a kind, those about who comes and goes aside.
func expect(c *trametest.Client, kind string) trametest.Frame {
	for {
		f := c.Next()
		switch f.T {
		case "join", "leave":
		default:
			if f.T != kind {
				c.Conn.Close()
				panic("got " + f.T + " frame, want " + kind + ": " + f.Error)
			}
			return f
		}
	}
}

// what the Flutter client writes, in the order it writes it
const drawn = `{"fresque":1,"elements":[
{"id":"b2","k":"r","z":5,"x":10,"y":20,"w":30,"h":40,"c":4278190080,"sw":2,"f":1},
{"id":"a1","k":"s","z":-2,"x":0,"y":0,"p":[0,0,1.5,2],"c":4294901760,"sw":3}
]}`

func TestAKeyOrdersAsTheStackDoes(t *testing.T) {
	zs := []int64{-zOffset, -1000, -1, 0, 1, 7, 255, 256, 1 << 30, zOffset - 1}
	for i, z := range zs {
		if back, ok := Z(Key(z)); !ok || back != z {
			t.Fatalf("Z(Key(%d)) = %d, %v", z, back, ok)
		}
		if i > 0 && Key(zs[i-1]) >= Key(z) {
			t.Fatalf("Key(%d) = %s does not sort before Key(%d) = %s", zs[i-1], Key(zs[i-1]), z, Key(z))
		}
	}
	// the Dart client writes the same keys (test/board_test.dart)
	if Key(0) != "10000000000" || Key(-1) != "0ffffffffff" {
		t.Fatalf("Key(0) = %s, Key(-1) = %s", Key(0), Key(-1))
	}
	for _, bad := range []string{"", "0", "0000000000A", "ffffffffffff", "zzzzzzzzzzz"} {
		if _, ok := Z(bad); ok {
			t.Errorf("%q is a position", bad)
		}
	}
}

func TestBoardsAreReadAndWrittenWithTheirElementsUntouched(t *testing.T) {
	store := trametest.NewStore()
	store.Data["b.fresque"] = []byte(drawn)
	h := NewHub(store, fast)

	alice, _, doc := join(t, h, "b.fresque", trame.Peer{ID: "1", Client: "a"})
	// a node per element, in the order of the stack: z -2 before z 5
	want := `[{"o":"new","id":"a1","t":"e","k":"` + Key(-2) + `","a":{"c":4294901760,"k":"s","p":[0,0,1.5,2],"sw":3,"x":0,"y":0}},` +
		`{"o":"new","id":"b2","t":"e","k":"` + Key(5) + `","a":{"c":4278190080,"f":1,"h":40,"k":"r","sw":2,"w":30,"x":10,"y":20}}]`
	if string(doc.D) != want {
		t.Fatalf("doc = %s\nwant  %s", doc.D, want)
	}

	alice.Send(`{"t":"op","n":1,"v":0,"d":[{"o":"set","id":"b2","a":{"x":11}}]}`)
	expect(alice, "ack")
	<-store.Saves
	saved := store.File("b.fresque")
	for _, line := range []string{
		`{"id":"a1","z":-2,"c":4294901760,"k":"s","p":[0,0,1.5,2],"sw":3,"x":0,"y":0}`,
		`{"id":"b2","z":5,"c":4278190080,"f":1,"h":40,"k":"r","sw":2,"w":30,"x":11,"y":20}`,
	} {
		if !strings.Contains(saved, "\n"+line) {
			t.Fatalf("saved board lacks %s:\n%s", line, saved)
		}
	}
	if !strings.HasPrefix(saved, `{"fresque":1,"elements":[`+"\n") || !strings.HasSuffix(saved, "\n]}\n") {
		t.Fatalf("saved = %q", saved)
	}
}

func TestEmptyAndUnreadableBoards(t *testing.T) {
	store := trametest.NewStore()
	h := NewHub(store, Options{})
	_, _, doc := join(t, h, "new.fresque", trame.Peer{ID: "1"})
	if string(doc.D) != `[]` {
		t.Fatalf("a board never saved holds %s", doc.D)
	}

	for name, data := range map[string]string{
		"not json":     `{"fresque":`,
		"other format": `{"fresque":2,"elements":[]}`,
		"no id":        `{"fresque":1,"elements":[{"k":"s"}]}`,
		"bad id":       `{"fresque":1,"elements":[{"id":"a b"}]}`,
	} {
		store.Data[name] = []byte(data)
		c := trametest.NewConn()
		if err := h.Serve(context.Background(), c, name, trame.Peer{ID: "1"}); err == nil {
			t.Errorf("%s: the board opens", name)
		}
	}
}

func TestElementsAreCreatedChangedAndDeleted(t *testing.T) {
	store := trametest.NewStore()
	h := NewHub(store, fast)
	alice, _, _ := join(t, h, "b.fresque", trame.Peer{ID: "1", Client: "a"})
	bob, _, _ := join(t, h, "b.fresque", trame.Peer{ID: "2", Client: "b"})

	alice.Send(`{"t":"op","n":1,"v":0,"d":[{"o":"new","id":"e1","t":"e","k":"` + Key(1) + `","a":{"k":"\"e\"","x":1}}]}`)
	expect(alice, "ack")
	if f := expect(bob, "op"); !strings.Contains(string(f.D), `"id":"e1"`) {
		t.Fatalf("bob was told %s", f.D)
	}
	bob.Send(`{"t":"op","n":1,"v":1,"d":[{"o":"set","id":"e1","k":"` + Key(9) + `","a":{"x":null,"y":4}}]}`)
	expect(bob, "ack")
	expect(alice, "op")
	alice.Send(`{"t":"op","n":2,"v":2,"d":[{"o":"del","id":"e1"}]}`)
	expect(alice, "ack")
	expect(bob, "op")
	<-store.Saves
	for store.File("b.fresque") != "{\"fresque\":1,\"elements\":[\n]}\n" {
		<-store.Saves
	}
}

func TestWhatIsNotABoardIsRefused(t *testing.T) {
	store := trametest.NewStore()
	store.Data["b.fresque"] = []byte(drawn)
	h := NewHub(store, Options{})
	c, _, _ := join(t, h, "b.fresque", trame.Peer{ID: "1", Client: "c"})
	ro, _, _ := join(t, h, "b.fresque", trame.Peer{ID: "2", Client: "r", ReadOnly: true})

	refused := []string{
		`[{"o":"txt","id":"a1","x":[{"i":"a"}]}]`,
		`[{"o":"new","id":"x1","t":"slide","k":"` + Key(0) + `","a":{"x":1}}]`,
		`[{"o":"new","id":"x1","t":"e","p":"a1","k":"` + Key(0) + `","a":{"x":1}}]`,
		`[{"o":"new","id":"x 1","t":"e","k":"` + Key(0) + `","a":{"x":1}}]`,
		`[{"o":"new","id":"x1","t":"e","k":"zz","a":{"x":1}}]`,
		`[{"o":"new","id":"x1","t":"e","k":"` + Key(0) + `","a":{"z":1}}]`,
		`[{"o":"set","id":"a1","a":{"id":"b2"}}]`,
		`[{"o":"set","id":"a1","k":"b"}]`,
	}
	for i, edit := range refused {
		c.Send(`{"t":"op","n":` + string(rune('1'+i)) + `,"v":0,"d":` + edit + `}`)
		if f := expect(c, "nack"); f.Error == "" {
			t.Errorf("%s: nack without a reason", edit)
		}
	}
	ro.Send(`{"t":"op","n":1,"v":0,"d":[{"o":"del","id":"a1"}]}`)
	if f := expect(ro, "nack"); f.Error != errReadOnly.Error() {
		t.Errorf("read-only: %q", f.Error)
	}
	c.Quiet()
}

func TestABoardKeepsToItsLimits(t *testing.T) {
	store := trametest.NewStore()
	store.Data["b.fresque"] = []byte(drawn)
	h := NewHub(store, Options{MaxElements: 3, MaxElementBytes: 300, MaxBoardBytes: 1000})
	c, _, _ := join(t, h, "b.fresque", trame.Peer{ID: "1", Client: "c"})

	add := func(n int, id, attrs string) trametest.Frame {
		c.Send(`{"t":"op","n":` + string(rune('0'+n)) + `,"v":0,"d":[{"o":"new","id":"` + id + `","t":"e","k":"` + Key(0) + `","a":` + attrs + `}]}`)
		return c.Next()
	}
	if f := add(1, "e1", `{"x":1}`); f.T != "ack" {
		t.Fatalf("first element: %+v", f)
	}
	if f := add(2, "e2", `{"x":1}`); f.T != "nack" || f.Error != errTooManyElements.Error() {
		t.Fatalf("fourth element: %+v", f)
	}
	// the one that is too big for an element
	c.Send(`{"t":"op","n":3,"v":0,"d":[{"o":"set","id":"a1","a":{"src":"` + strings.Repeat("x", 400) + `"}}]}`)
	if f := c.Next(); f.T != "nack" || f.Error != errElementTooLarge.Error() {
		t.Fatalf("large element: %+v", f)
	}
	// deleting always works, which is how an oversized board is cleaned up
	c.Send(`{"t":"op","n":4,"v":0,"d":[{"o":"del","id":"a1"},{"o":"del","id":"b2"}]}`)
	if f := c.Next(); f.T != "ack" {
		t.Fatalf("delete: %+v", f)
	}
	// and the room freed is room to grow in
	if f := add(5, "e3", `{"x":1}`); f.T != "ack" {
		t.Fatalf("after deleting: %+v", f)
	}
}
