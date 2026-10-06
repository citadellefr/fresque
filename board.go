package fresque

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"slices"
	"strconv"
	"strings"

	"github.com/citadellefr/trame"
	"github.com/citadellefr/trame/ot"
)

// Element is the type of every node of a board. What an element is — a
// stroke, a line, a rectangle — is its attribute "k", which the hub has no
// need to read: nothing it does depends on it, and an element a newer client
// draws with a kind this one does not know is kept as it is.
const Element = "e"

const (
	boardFormat = 1
	maxIDLength = 64
	// z, the place of an element in the stack, is the key of its node: an
	// integer written in hexadecimal, offset so that it sorts as it counts.
	// Small enough to be exact in a JavaScript number.
	zOffset = 1 << 40
	zDigits = 11
)

var (
	errReadOnly        = errors.New("read-only access")
	errNotElement      = errors.New("a board only has elements")
	errBadID           = errors.New("invalid element id")
	errBadKey          = errors.New("invalid element position")
	errReserved        = errors.New("id and z are not attributes")
	errElementTooLarge = errors.New("element too large")
	errBoardFull       = errors.New("board size limit reached")
	errTooManyElements = errors.New("board element limit reached")
)

// Key is the key of a node standing at z in the stack.
func Key(z int64) string {
	z = min(max(z, -zOffset), zOffset-1)
	return fmt.Sprintf("%0*x", zDigits, z+zOffset)
}

// Z is the place in the stack a key stands for.
func Z(key string) (int64, bool) {
	if len(key) != zDigits {
		return 0, false
	}
	n, err := strconv.ParseUint(key, 16, 64)
	if err != nil || n >= 2*zOffset || strings.ToLower(key) != key {
		return 0, false
	}
	return int64(n) - zOffset, true
}

func validID(s string) bool {
	if s == "" || len(s) > maxIDLength {
		return false
	}
	for i := range len(s) {
		c := s[i]
		if !('a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

// The board file: {"fresque":1,"elements":[...]}, one element per line and
// sorted by id, so that two saves of the same board are the same bytes. An
// element is a JSON object with its "id" and its "z", and whatever else it
// holds.
type boardFile struct {
	Format   int               `json:"fresque"`
	Elements []json.RawMessage `json:"elements"`
}

func decode(data []byte) (*ot.Tree, error) {
	if len(bytes.TrimSpace(data)) == 0 {
		return ot.NewTree(nil)
	}
	var f boardFile
	if err := json.Unmarshal(data, &f); err != nil {
		return nil, fmt.Errorf("fresque: unreadable board: %w", err)
	}
	if f.Format != boardFormat {
		return nil, fmt.Errorf("fresque: unsupported board format %d", f.Format)
	}
	// the last of two elements with the same id is the one that stands
	last := map[string]ot.Change{}
	for _, raw := range f.Elements {
		c, err := element(raw)
		if err != nil {
			return nil, err
		}
		last[c.ID] = c
	}
	nodes := make(ot.Edit, 0, len(last))
	for _, c := range last {
		nodes = append(nodes, c)
	}
	return ot.NewTree(nodes)
}

func element(raw json.RawMessage) (ot.Change, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return ot.Change{}, fmt.Errorf("fresque: unreadable element: %w", err)
	}
	var id string
	if json.Unmarshal(fields["id"], &id) != nil || !validID(id) {
		return ot.Change{}, errBadID
	}
	var z float64
	_ = json.Unmarshal(fields["z"], &z)
	if math.IsNaN(z) {
		z = 0
	}
	delete(fields, "id")
	delete(fields, "z")
	attrs := ot.Values{}
	for k, v := range fields {
		if k != "" && len(v) > 0 && !bytes.Equal(v, []byte("null")) {
			attrs[k] = v
		}
	}
	return ot.Change{Op: ot.OpNew, ID: id, Type: Element, Key: Key(int64(z)), Attrs: attrs}, nil
}

// board is a board file, and what the hub needs to hold it to its limits.
type board struct {
	opt Options
	// sizes are those of the elements as the file writes them, and size
	// their sum: Check and Follow are called with the room locked.
	sizes map[string]int
	size  int
}

// size is what an element takes in the file.
func size(id string, attrs ot.Values) int {
	n := len(id) + 24
	for k, v := range attrs {
		n += len(k) + len(v) + 4
	}
	return n
}

func (b *board) Check(doc *ot.Tree, e ot.Edit, by trame.Peer) error {
	if by.ReadOnly {
		return errReadOnly
	}
	count, total := doc.Len(), b.size
	sizes := map[string]int{}
	has := func(id string) (int, bool) {
		if n, ok := sizes[id]; ok {
			return n, n >= 0
		}
		n, ok := b.sizes[id]
		return n, ok
	}
	for _, c := range e {
		if err := checkChange(c); err != nil {
			return err
		}
		old, exists := has(c.ID)
		var grown int
		switch c.Op {
		case ot.OpNew:
			if exists {
				continue
			}
			grown = size(c.ID, c.Attrs)
			count++
		case ot.OpSet:
			if !exists {
				continue
			}
			grown = old
			for k, v := range c.Attrs {
				if n := doc.Node(c.ID); n != nil {
					grown -= len(k) + len(n.Attrs[k]) + 4
				}
				if !bytes.Equal(v, []byte("null")) {
					grown += len(k) + len(v) + 4
				}
			}
			grown = max(grown, 0)
		case ot.OpDel:
			if exists {
				count--
				total -= old
				sizes[c.ID] = -1
			}
			continue
		}
		if grown > b.opt.MaxElementBytes && grown > old {
			return errElementTooLarge
		}
		total += grown - old
		sizes[c.ID] = grown
	}
	if total > b.size && total > b.opt.MaxBoardBytes {
		return errBoardFull
	}
	if count > doc.Len() && count > b.opt.MaxElements {
		return errTooManyElements
	}
	return nil
}

func checkChange(c ot.Change) error {
	switch c.Op {
	case ot.OpNew:
		if c.Type != Element || c.Parent != "" || c.Text != nil || c.Cells != nil {
			return errNotElement
		}
		if !validID(c.ID) {
			return errBadID
		}
	case ot.OpSet, ot.OpDel:
	default:
		return errNotElement
	}
	if c.Key != "" {
		if _, ok := Z(c.Key); !ok {
			return errBadKey
		}
	}
	if _, id := c.Attrs["id"]; id {
		return errReserved
	}
	if _, z := c.Attrs["z"]; z {
		return errReserved
	}
	return nil
}

// Follow keeps the sizes of the elements an edit changed.
func (b *board) Follow(doc *ot.Tree, e ot.Edit, _ []ot.Edit, _ trame.Peer) ot.Edit {
	for _, c := range e {
		n := doc.Node(c.ID)
		b.size -= b.sizes[c.ID]
		if n == nil {
			delete(b.sizes, c.ID)
			continue
		}
		b.sizes[c.ID] = size(n.ID, n.Attrs)
		b.size += b.sizes[c.ID]
	}
	return nil
}

func (b *board) Encode(doc *ot.Tree) ([]byte, error) {
	nodes := slices.Clone(doc.Children(""))
	slices.SortFunc(nodes, func(a, b *ot.Node) int { return strings.Compare(a.ID, b.ID) })
	var out bytes.Buffer
	out.WriteString(`{"fresque":1,"elements":[`)
	for i, n := range nodes {
		if i > 0 {
			out.WriteByte(',')
		}
		out.WriteByte('\n')
		z, _ := Z(n.Key)
		fmt.Fprintf(&out, `{"id":%q,"z":%d`, n.ID, z)
		for _, k := range slices.Sorted(mapsKeys(n.Attrs)) {
			key, _ := json.Marshal(k)
			out.WriteByte(',')
			out.Write(key)
			out.WriteByte(':')
			out.Write(n.Attrs[k])
		}
		out.WriteByte('}')
	}
	out.WriteString("\n]}\n")
	return out.Bytes(), nil
}

func mapsKeys(v ot.Values) func(yield func(string) bool) {
	return func(yield func(string) bool) {
		for k := range v {
			if !yield(k) {
				return
			}
		}
	}
}
