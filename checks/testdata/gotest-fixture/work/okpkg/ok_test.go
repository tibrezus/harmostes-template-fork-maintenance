package okpkg

import "testing"

func TestOk(t *testing.T) {
	if Ok() != 1 {
		t.Fatal("ok broke")
	}
}
