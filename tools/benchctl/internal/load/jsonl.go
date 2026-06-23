package load

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

type Writer struct {
	mu     sync.Mutex
	f      *os.File
	closed bool
}

func NewWriter(path string) (*Writer, error) {
	if err := ensureParentDir(path); err != nil {
		return nil, err
	}
	f, err := os.Create(path)
	if err != nil {
		return nil, err
	}
	return &Writer{f: f}, nil
}

func (w *Writer) Write(event Event) error {
	w.mu.Lock()
	defer w.mu.Unlock()

	if w.closed {
		return errors.New("jsonl writer is closed")
	}

	b, err := json.Marshal(event)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	if _, err := w.f.Write(b); err != nil {
		return err
	}
	return nil
}

func (w *Writer) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()

	if w.closed {
		return nil
	}
	w.closed = true
	return w.f.Close()
}

func ReadEvents(path string) ([]Event, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	var events []Event
	line := 0
	for sc.Scan() {
		line++
		var event Event
		if err := json.Unmarshal(sc.Bytes(), &event); err != nil {
			return nil, fmt.Errorf("%s:%d: %w", path, line, err)
		}
		events = append(events, event)
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return events, nil
}

func WriteSummary(path string, summary Summary) error {
	if path == "" {
		return nil
	}
	return writeJSONFile(path, summary)
}

func WriteManifest(path string, manifest RunManifest) error {
	if path == "" {
		return nil
	}
	return writeJSONFile(path, manifest)
}

func writeJSONFile(path string, value any) error {
	if err := ensureParentDir(path); err != nil {
		return err
	}
	b, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	b = append(b, '\n')
	return os.WriteFile(path, b, 0o644)
}

func ensureParentDir(path string) error {
	dir := filepath.Dir(path)
	if dir == "." || dir == "" {
		return nil
	}
	return os.MkdirAll(dir, 0o755)
}
