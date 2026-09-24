package fresque

import (
	"context"
	"strconv"
	"testing"
	"time"
)

// BenchmarkRelay measures what one edit costs the hub: decoding, applying and
// fanning it out to eight peers.
func BenchmarkRelay(b *testing.B) {
	for _, kind := range []struct{ name, frame string }{
		{"op", `{"t":"op","n":1,"put":[{"id":"stroke1","k":"s","z":4,"x":120.5,"y":80,"p":[0,0,1.5,2,3,4.5,6,7,9,10.5,12,14,15.5,18,19,21],"c":4280163870,"sw":3}]}`},
		{"presence", `{"t":"eph","d":{"c":[512,384]}}`},
	} {
		b.Run(kind.name, func(b *testing.B) {
			h := NewHub(newMemStore(), Options{SaveDelay: time.Hour, SaveMaxDelay: time.Hour, PresenceRate: 1 << 30})
			r, err := h.acquire(context.Background(), "b")
			if err != nil {
				b.Fatal(err)
			}
			var peers []*peer
			for i := range 9 {
				p := newPeer(newFakeConn(), Peer{ID: strconv.Itoa(i)}, h.opt.PresenceRate)
				r.join(p)
				peers = append(peers, p)
				go func() {
					for {
						select {
						case <-p.out:
						case <-p.done:
							return
						}
					}
				}()
			}
			msg := []byte(kind.frame)
			b.ReportAllocs()
			b.ResetTimer()
			for range b.N {
				r.handle(peers[0], msg)
			}
			b.StopTimer()
			for _, p := range peers {
				p.close(0, "")
			}
		})
	}
}
