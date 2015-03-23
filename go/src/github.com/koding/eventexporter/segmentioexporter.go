package eventexporter

import (
	analytics "github.com/segmentio/analytics-go"
)

type SegementIOExporter struct {
	Client *analytics.Client
}

func NewSegementIOExporter(key string, size int) *SegementIOExporter {
	client := analytics.New(key) // access token to authorize requests
	client.Size = size           // size of queue before flushing to api

	return &SegementIOExporter{Client: client}
}

func (s *SegementIOExporter) Send(event *Event) error {
	trackEvent, err := buildTrack(event)
	if err != nil {
		return err
	}

	return s.Client.Track(trackEvent)
}

func buildTrack(event *Event) (*analytics.Track, error) {
	if event.User.Username == "" {
		return nil, ErrSegmentIOUsernameEmpty
	}

	if event.User.Email == "" {
		return nil, ErrSegmentIOEmailEmpty
	}

	if event.Name == "" {
		return nil, ErrSegmentIOEventEmpty
	}

	event = addBody(event)
	event.Properties["email"] = event.User.Email

	return &analytics.Track{
		Event:      event.Name,
		UserId:     event.User.Username,
		Properties: event.Properties,
	}, nil
}

func addBody(event *Event) *Event {
	_, ok := event.Properties["body"]
	if ok {
		return event
	}

	if event.Body != nil {
		if event.Properties == nil {
			event.Properties = map[string]interface{}{}
		}

		event.Properties["body"] = event.Body.Content
		event.Properties["bodyType"] = event.Body.Type
	}

	return event
}
