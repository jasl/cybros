package client

import (
	"fmt"
	"time"
)

type HTTPError struct {
	StatusCode int
	Body       string
	RetryAfter time.Duration
}

func (e HTTPError) Error() string {
	if e.RetryAfter > 0 {
		return fmt.Sprintf("HTTP %d (retry after %s): %s", e.StatusCode, e.RetryAfter, e.Body)
	}
	return fmt.Sprintf("HTTP %d: %s", e.StatusCode, e.Body)
}
