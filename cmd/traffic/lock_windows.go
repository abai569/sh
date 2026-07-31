package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

var windowsFileLock sync.Mutex

func acquireFileLock(path string) (func(), error) {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return nil, fmt.Errorf("create lock directory: %w", err)
	}
	windowsFileLock.Lock()
	return windowsFileLock.Unlock, nil
}
