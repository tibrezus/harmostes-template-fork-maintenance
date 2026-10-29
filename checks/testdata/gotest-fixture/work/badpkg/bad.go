package badpkg

// Bad returns the CONTRACT value the test pins. The CI fixture step flips
// this to 3 and expects the gate to fail — the mutation IS the proof.
func Bad() int { return 2 }
