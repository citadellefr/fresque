package fresque

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"
)

const (
	textMessage  = 1
	closeMessage = 8
	pingMessage  = 9

	maxIDLength       = 64
	maxPresenceBytes  = 16 << 10
	boardFormat       = 1
	closeReasonLength = 123
)

var errBadID = errors.New("invalid element id")

// inbound is any frame a client sends:
//
//	{"t":"op","n":7,"put":[{"id":"a1",...}],"del":["b2"]}
//	{"t":"eph","d":{...}}
type inbound struct {
	T   string          `json:"t"`
	N   uint64          `json:"n"`
	Put []element       `json:"put"`
	Del []elementID     `json:"del"`
	D   json.RawMessage `json:"d"`
}

type element struct {
	id  string
	raw []byte
}

func (e *element) UnmarshalJSON(b []byte) error {
	var head struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(b, &head); err != nil {
		return err
	}
	if !validID(head.ID) {
		return errBadID
	}
	e.id, e.raw = head.ID, bytes.Clone(b)
	return nil
}

type elementID string

func (id *elementID) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	if !validID(s) {
		return errBadID
	}
	*id = elementID(s)
	return nil
}

// validID keeps ids free of anything JSON would escape, which lets frames be
// assembled by appending bytes.
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

func opFrame(sid uint32, put []element, del []elementID) []byte {
	size := 40
	for _, e := range put {
		size += len(e.raw) + 1
	}
	for _, id := range del {
		size += len(id) + 3
	}
	b := make([]byte, 0, size)
	b = append(b, `{"t":"op","sid":`...)
	b = strconv.AppendUint(b, uint64(sid), 10)
	if len(put) > 0 {
		b = append(b, `,"put":[`...)
		for i, e := range put {
			if i > 0 {
				b = append(b, ',')
			}
			b = append(b, e.raw...)
		}
		b = append(b, ']')
	}
	if len(del) > 0 {
		b = append(b, `,"del":[`...)
		for i, id := range del {
			if i > 0 {
				b = append(b, ',')
			}
			b = append(b, '"')
			b = append(b, id...)
			b = append(b, '"')
		}
		b = append(b, ']')
	}
	return append(b, '}')
}

func presenceFrame(sid uint32, d []byte) []byte {
	b := make([]byte, 0, len(d)+32)
	b = append(b, `{"t":"eph","sid":`...)
	b = strconv.AppendUint(b, uint64(sid), 10)
	b = append(b, `,"d":`...)
	b = append(b, d...)
	return append(b, '}')
}

func ackFrame(n, version uint64) []byte {
	b := make([]byte, 0, 48)
	b = append(b, `{"t":"ack","n":`...)
	b = strconv.AppendUint(b, n, 10)
	b = append(b, `,"v":`...)
	b = strconv.AppendUint(b, version, 10)
	return append(b, '}')
}

func savedFrame(version uint64) []byte {
	b := append([]byte(`{"t":"saved","v":`), strconv.FormatUint(version, 10)...)
	return append(b, '}')
}

func messageFrame(t string, n uint64, message string) []byte {
	f, _ := json.Marshal(struct {
		T     string `json:"t"`
		N     uint64 `json:"n,omitempty"`
		Error string `json:"error"`
	}{t, n, message})
	return f
}

type peerView struct {
	SID      uint32 `json:"sid"`
	ID       string `json:"id"`
	Name     string `json:"name"`
	ReadOnly bool   `json:"ro,omitempty"`
}

func joinFrame(p peerView) []byte {
	f, _ := json.Marshal(struct {
		T    string   `json:"t"`
		Peer peerView `json:"peer"`
	}{"join", p})
	return f
}

func leaveFrame(sid uint32) []byte {
	b := append([]byte(`{"t":"leave","sid":`), strconv.FormatUint(uint64(sid), 10)...)
	return append(b, '}')
}

// helloFrame is the first frame of a connection: who it is, who else is
// there, the whole board, and the last edit of its client the hub applied.
type hello struct {
	SID      uint32     `json:"sid"`
	Ack      uint64     `json:"ack"`
	Version  uint64     `json:"v"`
	Saved    uint64     `json:"saved"`
	ReadOnly bool       `json:"ro,omitempty"`
	Error    string     `json:"error,omitempty"`
	Peers    []peerView `json:"peers"`
}

func helloFrame(h hello, elements [][]byte) []byte {
	head, _ := json.Marshal(h)
	size := len(head) + 32
	for _, e := range elements {
		size += len(e) + 1
	}
	b := make([]byte, 0, size)
	b = append(b, `{"t":"hello",`...)
	b = append(b, head[1:len(head)-1]...)
	b = append(b, `,"elements":[`...)
	for i, e := range elements {
		if i > 0 {
			b = append(b, ',')
		}
		b = append(b, e...)
	}
	return append(b, "]}"...)
}

func closePayload(code int, reason string) []byte {
	if len(reason) > closeReasonLength {
		reason = truncateUTF8(reason, closeReasonLength)
	}
	return append([]byte{byte(code >> 8), byte(code)}, reason...)
}

func truncateUTF8(s string, n int) string {
	for n > 0 && n < len(s) && s[n]&0xC0 == 0x80 {
		n--
	}
	return s[:n]
}

// The board file: {"fresque":1,"elements":[...]}, one element per line and
// sorted by id, so that two saves of the same board are the same bytes.
type boardFile struct {
	Format   int       `json:"fresque"`
	Elements []element `json:"elements"`
}

func decodeBoard(data []byte) (map[string][]byte, int, error) {
	elements := map[string][]byte{}
	if len(bytes.TrimSpace(data)) == 0 {
		return elements, 0, nil
	}
	var f boardFile
	if err := json.Unmarshal(data, &f); err != nil {
		return nil, 0, fmt.Errorf("fresque: unreadable board: %w", err)
	}
	if f.Format != boardFormat {
		return nil, 0, fmt.Errorf("fresque: unsupported board format %d", f.Format)
	}
	size := 0
	for _, e := range f.Elements {
		size += len(e.raw) - len(elements[e.id])
		elements[e.id] = e.raw
	}
	return elements, size, nil
}

func encodeBoard(elements []element) []byte {
	slices.SortFunc(elements, func(a, b element) int { return strings.Compare(a.id, b.id) })
	size := 32
	for _, e := range elements {
		size += len(e.raw) + 2
	}
	b := make([]byte, 0, size)
	b = append(b, `{"fresque":1,"elements":[`...)
	for i, e := range elements {
		if i > 0 {
			b = append(b, ',')
		}
		b = append(b, '\n')
		b = append(b, e.raw...)
	}
	return append(b, "\n]}\n"...)
}
