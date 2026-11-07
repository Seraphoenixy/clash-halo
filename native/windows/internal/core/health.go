package core

import (
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// probeHTTP performs a bounded GET against the core controller.
func probeHTTP(url, secret string, timeout time.Duration) error {
	if timeout <= 0 {
		timeout = 3 * time.Second
	}
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	if secret != "" {
		req.Header.Set("Authorization", "Bearer "+secret)
	}
	client := &http.Client{Timeout: timeout}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("核心控制接口无响应: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("核心控制接口返回 %d: %s", resp.StatusCode,
			strings.TrimSpace(string(body)))
	}
	return nil
}
