package presence

import (
	"errors"
	"net/http"
	"net/url"
	"path"
	"sync"

	"koding/socialapi"
)

type Client struct {
	Endpoint *url.URL     // presence endpoint of socialapi
	Client   *http.Client // client with *socialapi.Transport transport

	once    sync.Once // for c.init()
	pingURL string
}

func (c *Client) Ping(username, team string) error {
	c.init()

	req, err := http.NewRequest("GET", c.pingURL, nil)
	if err != nil {
		return err
	}

	req = (&socialapi.Session{
		Username: username,
		Team:     team,
	}).WithRequest(req)

	resp, err := c.Client.Do(req)
	if err != nil {
		return err
	}

	switch resp.StatusCode {
	case http.StatusOK, http.StatusNoContent:
		return nil
	default:
		return errors.New(resp.Status)
	}
}

func (c *Client) init() {
	c.once.Do(c.initClient)
}

func (c *Client) initClient() {
	pingURL := *c.Endpoint
	pingURL.Path = path.Join(pingURL.Path, "ping")
	c.pingURL = pingURL.String()
}
