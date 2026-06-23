package load

import (
	"os"
	"sync"
	"sync/atomic"
	"time"
)

func Run(cfg Config) error {
	if err := cfg.Validate(); err != nil {
		return err
	}

	body, err := os.ReadFile(cfg.Fixture)
	if err != nil {
		return err
	}

	writer, err := NewWriter(cfg.Output)
	if err != nil {
		return err
	}
	defer writer.Close()

	var totalEvents int64
	var measuredEvents int64
	var warmupEvents int64
	var success2xx int64
	var errorEvents int64

	var errMu sync.Mutex
	var firstErr error
	setFirstErr := func(err error) {
		if err == nil {
			return
		}
		errMu.Lock()
		defer errMu.Unlock()
		if firstErr == nil {
			firstErr = err
		}
	}
	getFirstErr := func() error {
		errMu.Lock()
		defer errMu.Unlock()
		return firstErr
	}

	record := func(event Event) {
		if event.Warmup {
			atomic.AddInt64(&warmupEvents, 1)
		} else {
			atomic.AddInt64(&measuredEvents, 1)
		}
		atomic.AddInt64(&totalEvents, 1)
		if event.Error != "" {
			atomic.AddInt64(&errorEvents, 1)
		}
		if event.Status >= 200 && event.Status < 300 {
			atomic.AddInt64(&success2xx, 1)
		}
		setFirstErr(writer.Write(event))
	}

	runPhaseClosedLoop := func(duration time.Duration, warmup bool) {
		deadline := time.Now().Add(duration)
		var wg sync.WaitGroup

		for worker := 0; worker < cfg.Concurrency; worker++ {
			workerID := worker
			wg.Add(1)

			go func() {
				defer wg.Done()
				client := newClient()

				for {
					now := time.Now()
					if !now.Before(deadline) {
						return
					}

					start := time.Now()
					status, reqErr := doRequest(client, cfg.URL, body)
					end := time.Now()

					record(Event{
						Service:           cfg.Service,
						Variant:           cfg.Variant,
						Cell:              cfg.Cell,
						Repeat:            cfg.Repeat,
						Warmup:            warmup,
						Worker:            workerID,
						Status:            status,
						LatencyMicros:     end.Sub(start).Microseconds(),
						ScheduledUnixNano: start.UnixNano(),
						StartedUnixNano:   start.UnixNano(),
						TimestampUnixNano: end.UnixNano(),
						Error:             errString(reqErr),
					})
				}
			}()
		}

		wg.Wait()
	}

	runPhaseRateLimited := func(duration time.Duration, warmup bool) {
		startBase := time.Now()
		endBase := startBase.Add(duration)

		var counter uint64
		var wg sync.WaitGroup

		for worker := 0; worker < cfg.Concurrency; worker++ {
			workerID := worker
			wg.Add(1)

			go func() {
				defer wg.Done()
				client := newClient()

				for {
					seq := atomic.AddUint64(&counter, 1) - 1
					offset := time.Duration(float64(seq) * float64(time.Second) / cfg.Rate)
					scheduled := startBase.Add(offset)
					if !scheduled.Before(endBase) {
						return
					}

					if sleep := time.Until(scheduled); sleep > 0 {
						time.Sleep(sleep)
					}

					started := time.Now()
					status, reqErr := doRequest(client, cfg.URL, body)
					end := time.Now()

					record(Event{
						Service:           cfg.Service,
						Variant:           cfg.Variant,
						Cell:              cfg.Cell,
						Repeat:            cfg.Repeat,
						Warmup:            warmup,
						Worker:            workerID,
						Status:            status,
						LatencyMicros:     end.Sub(started).Microseconds(),
						ScheduledUnixNano: scheduled.UnixNano(),
						StartedUnixNano:   started.UnixNano(),
						TimestampUnixNano: end.UnixNano(),
						Error:             errString(reqErr),
					})
				}
			}()
		}

		wg.Wait()
	}

	if cfg.Warmup > 0 {
		if cfg.Rate > 0 {
			runPhaseRateLimited(cfg.Warmup, true)
		} else {
			runPhaseClosedLoop(cfg.Warmup, true)
		}
	}

	if cfg.Rate > 0 {
		runPhaseRateLimited(cfg.Duration, false)
	} else {
		runPhaseClosedLoop(cfg.Duration, false)
	}

	if err := getFirstErr(); err != nil {
		return err
	}

	summary := Summary{
		Service:        cfg.Service,
		Variant:        cfg.Variant,
		Cell:           cfg.Cell,
		Repeat:         cfg.Repeat,
		WarmupDuration: cfg.Warmup.Nanoseconds(),
		Duration:       cfg.Duration.Nanoseconds(),
		Concurrency:    cfg.Concurrency,
		Rate:           cfg.Rate,
		TotalEvents:    atomic.LoadInt64(&totalEvents),
		MeasuredEvents: atomic.LoadInt64(&measuredEvents),
		WarmupEvents:   atomic.LoadInt64(&warmupEvents),
		Success2xx:     atomic.LoadInt64(&success2xx),
		Errors:         atomic.LoadInt64(&errorEvents),
		Output:         cfg.Output,
		SummaryOutput:  cfg.SummaryOutput,
	}
	if err := WriteSummary(cfg.SummaryOutput, summary); err != nil {
		return err
	}

	return nil
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
