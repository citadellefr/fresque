// Package fresque serves collaborative whiteboards. The hub is trame's; this
// package is the format of the boards: a board is a set of elements — strokes,
// shapes, texts, pictures — each a node of the document, stacked by the order
// of their keys. An edit creates, changes or deletes elements, and trame
// rebases it over the edits of others, so that everyone ends on the same
// board.
package fresque

import (
	"github.com/citadellefr/trame"
	"github.com/citadellefr/trame/ot"
)

// What the host of a hub handles are trame's own types.
type (
	Conn  = trame.Conn
	Store = trame.Store
	Peer  = trame.Peer
	Hub   = trame.Hub
)

// Close codes sent to a client whose connection the hub ends.
const (
	CloseLoadFailed = trame.CloseLoadFailed
	CloseRevoked    = trame.CloseRevoked
	CloseTooSlow    = trame.CloseTooSlow
	CloseShutdown   = trame.CloseShutdown
)

var (
	ErrClosed = trame.ErrClosed
	// ErrGone is what Store.Save returns, possibly wrapped, when the board no
	// longer exists: everyone connected to it is disconnected.
	ErrGone = trame.ErrGone
)

// Options tunes a hub of boards. Zero fields take the defaults.
type Options struct {
	trame.Options
	// The limits only refuse what grows a board, so that an oversized one can
	// still be cleaned up.
	MaxElements     int
	MaxElementBytes int
	MaxBoardBytes   int
}

func (o Options) withDefaults() Options {
	if o.MaxElements <= 0 {
		o.MaxElements = 50_000
	}
	if o.MaxElementBytes <= 0 {
		o.MaxElementBytes = 256 << 10
	}
	if o.MaxBoardBytes <= 0 {
		o.MaxBoardBytes = 32 << 20
	}
	return o
}

// NewHub serves boards from store.
func NewHub(store trame.Store, opt Options) *trame.Hub {
	return trame.NewHub(store, Format(opt), opt.Options)
}

// Format reads boards, for a hub that serves them among other documents; its
// trame.Options are not used.
func Format(opt Options) trame.Format {
	opt = opt.withDefaults()
	return func(_ string, data []byte) (*ot.Tree, trame.File, error) {
		doc, err := decode(data)
		if err != nil {
			return nil, nil, err
		}
		b := &board{opt: opt, sizes: map[string]int{}}
		for _, n := range doc.Children("") {
			b.sizes[n.ID] = size(n.ID, n.Attrs)
			b.size += b.sizes[n.ID]
		}
		return doc, b, nil
	}
}
