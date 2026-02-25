package client

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"cybros.ai/nexus/config"
	"cybros.ai/nexus/protocol"
)

type Client struct {
	baseURL     string
	hc          *http.Client
	territoryID string
}

func New(cfg config.Config) (*Client, error) {
	tlsCfg, err := buildTLSConfig(cfg.TLS)
	if err != nil {
		return nil, err
	}
	hc := &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: tlsCfg,
		},
		Timeout: cfg.Poll.LongPollTimeout,
	}
	return &Client{
		baseURL:     strings.TrimSuffix(cfg.ServerURL, "/"),
		hc:          hc,
		territoryID: cfg.TerritoryID,
	}, nil
}

func buildTLSConfig(c config.TLSConfig) (*tls.Config, error) {
	tlsCfg := &tls.Config{
		MinVersion:         tls.VersionTLS12,
		InsecureSkipVerify: c.InsecureSkipVerify,
	}
	if c.CAFile != "" {
		caPEM, err := os.ReadFile(c.CAFile)
		if err != nil {
			return nil, fmt.Errorf("read CA file: %w", err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(caPEM) {
			return nil, fmt.Errorf("failed to parse CA bundle")
		}
		tlsCfg.RootCAs = pool
	}
	if c.ClientCertFile != "" && c.ClientKeyFile != "" {
		cert, err := tls.LoadX509KeyPair(c.ClientCertFile, c.ClientKeyFile)
		if err != nil {
			return nil, fmt.Errorf("load client cert/key: %w", err)
		}
		tlsCfg.Certificates = []tls.Certificate{cert}
	}
	return tlsCfg, nil
}

func (c *Client) Poll(ctx context.Context, req protocol.PollRequest) (protocol.PollResponse, error) {
	var out protocol.PollResponse
	err := c.postJSON(ctx, "/conduits/v1/polls", "", req, &out)
	return out, err
}

func (c *Client) Enroll(ctx context.Context, req protocol.EnrollRequest) (protocol.EnrollResponse, error) {
	var out protocol.EnrollResponse
	err := c.postJSON(ctx, "/conduits/v1/territories/enroll", "", req, &out)
	return out, err
}

func (c *Client) TerritoryHeartbeat(ctx context.Context, req protocol.TerritoryHeartbeatRequest) (protocol.TerritoryHeartbeatResponse, error) {
	var out protocol.TerritoryHeartbeatResponse
	err := c.postJSON(ctx, "/conduits/v1/territories/heartbeat", "", req, &out)
	return out, err
}

func (c *Client) Started(ctx context.Context, directiveID, directiveToken string, req protocol.StartedRequest) error {
	return c.postJSON(ctx, fmt.Sprintf("/conduits/v1/directives/%s/started", directiveID), directiveToken, req, nil)
}

func (c *Client) Heartbeat(ctx context.Context, directiveID, directiveToken string, req protocol.HeartbeatRequest) (protocol.HeartbeatResponse, error) {
	var out protocol.HeartbeatResponse
	err := c.postJSON(ctx, fmt.Sprintf("/conduits/v1/directives/%s/heartbeat", directiveID), directiveToken, req, &out)
	return out, err
}

func (c *Client) LogChunk(ctx context.Context, directiveID, directiveToken string, req protocol.LogChunkRequest) error {
	return c.postJSON(ctx, fmt.Sprintf("/conduits/v1/directives/%s/log_chunks", directiveID), directiveToken, req, nil)
}

func (c *Client) Finished(ctx context.Context, directiveID, directiveToken string, req protocol.FinishedRequest) error {
	return c.postJSON(ctx, fmt.Sprintf("/conduits/v1/directives/%s/finished", directiveID), directiveToken, req, nil)
}

func (c *Client) postJSON(ctx context.Context, path string, directiveToken string, in any, out any) error {
	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(b)
	} else {
		body = bytes.NewReader([]byte("{}"))
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+path, body)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.territoryID != "" {
		// Dev convenience: real auth should come from mTLS identity at the edge.
		req.Header.Set("X-Nexus-Territory-Id", c.territoryID)
	}
	if directiveToken != "" {
		req.Header.Set("Authorization", "Bearer "+directiveToken)
	}

	resp, err := c.hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	b, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		var retryAfter time.Duration
		if ra := strings.TrimSpace(resp.Header.Get("Retry-After")); ra != "" {
			if seconds, err := strconv.Atoi(ra); err == nil && seconds > 0 {
				retryAfter = time.Duration(seconds) * time.Second
			}
		}
		return HTTPError{
			StatusCode: resp.StatusCode,
			Body:       string(b),
			RetryAfter: retryAfter,
		}
	}
	if out == nil {
		return nil
	}
	if len(b) == 0 {
		return nil
	}
	if err := json.Unmarshal(b, out); err != nil {
		return fmt.Errorf("decode response: %w", err)
	}
	return nil
}

// WithTimeout returns a context with a default timeout (used for non-poll requests).
func WithTimeout(parent context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(parent, 10*time.Second)
}
