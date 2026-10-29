package badpkg

import "testing"

func TestBad(t *testing.T) {
	if Bad() != 2 {
		t.Fatal("contract violated")
	}
}
