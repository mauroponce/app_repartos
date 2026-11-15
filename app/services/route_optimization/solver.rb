module RouteOptimization
  # All moves are evaluated in their actual direction, including reversed arcs.
  # Objective: mandatory violations first, then total elapsed time + preferred
  # time penalty (2 seconds per second outside tolerance), then driving/metres.
  class Solver
    attr_reader :stops, :durations, :distances, :evaluations

    def initialize(stops:, durations:, distances:, departure: 28_800, depot_index: nil, return_to_depot: false, tolerance: 900, max_evaluations: 18_000)
      @stops, @durations, @distances = stops, durations, distances
      @departure, @depot_index, @return, @tolerance = departure, depot_index, return_to_depot, tolerance
      @budget, @evaluations = max_evaluations, 0
      raise ArgumentError, "Las paradas deben ser únicas" unless stops.map { |row| row.fetch(:id) }.uniq.size == stops.size
      raise ArgumentError, "El regreso requiere un depósito" if @return && @depot_index.nil?
      size = stops.size + (@depot_index.nil? ? 0 : 1)
      unless [ durations, distances ].all? { |matrix| matrix.size == size && matrix.all? { |row| row.size == size && row.all? { |value| value.nil? || (value.is_a?(Numeric) && value.finite? && value >= 0) } } }
        raise ArgumentError, "La matriz vial no corresponde a las paradas"
      end
      raise ArgumentError, "Los índices de las paradas no corresponden a la matriz" unless (stops.map { |row| row.fetch(:index) } + [ @depot_index ].compact).sort == (0...size).to_a
    end

    def call(exact: stops.size <= 7)
      @evaluations = 0
      original = evaluate(stops)
      best = original
      algorithm = exact ? "exact" : "heuristic"
      if exact
        stops.permutation.each do |rows|
          value = evaluate(rows)
          best = value if better?(value, best)
        end
      else
        seeds = [ stops, insertion ]
        choices = stops.size <= 15 ? stops : stops.values_at(*[ 0, stops.size / 4, stops.size / 2, stops.size - 1 ].uniq)
        choices.each { |first| seeds << nearest(first) }
        seeds = seeds.uniq { |rows| rows.map { |stop| stop[:id] } }.sort_by { |rows| score(evaluate(rows)) }
        seeds.each do |rows|
          initial = evaluate(rows)
          best = initial if better?(initial, best)
        end
        seeds.each do |rows|
          candidate = improve(rows)
          best = candidate if better?(candidate, best)
          break if evaluations >= @budget
        end
      end
      # Equal objective retains the administrator's current order.
      best = original unless better?(best, original)
      { original: original, proposed: best, improved: better?(best, original), algorithm: algorithm, evaluations: evaluations,
        objective: "Ventanas obligatorias; duración total más penalización de preferencia; conducción y distancia como desempate" }
    end

    def evaluate(rows)
      @evaluations += 1
      clock, previous = @departure.to_f, @depot_index
      driving = distance = waiting = service = penalty = violations = violation_seconds = 0
      arrivals = []
      rows.each do |stop|
        if previous
          time, meters = durations[previous][stop[:index]], distances[previous][stop[:index]]
          if time.nil? || meters.nil?
            violations += 1
            violation_seconds += 86_400
          else
            clock += time
            driving += time
            distance += meters
          end
        end
        arrival = clock
        wait = [ stop.fetch(:window_start, 0).to_f - clock, 0 ].max
        waiting += wait
        clock += wait
        late = stop[:window_end] ? [ clock - stop[:window_end], 0 ].max : 0
        if late.positive?
          violations += 1
          violation_seconds += late
        end
        preference = stop[:preferred] ? [ (clock - stop[:preferred]).abs - @tolerance, 0 ].max : 0
        penalty += preference * 2
        finish = clock + stop.fetch(:service, 0)
        arrivals << { id: stop[:id], arrival: arrival.round(2), service_start: clock.round(2), finish: finish.round(2), waiting: wait.round(2), late: late.round(2), preference_deviation: preference.round(2) }
        service += stop.fetch(:service, 0)
        clock = finish
        previous = stop[:index]
      end
      if @return && previous && rows.any?
        time, meters = durations[previous][@depot_index], distances[previous][@depot_index]
        if time.nil? || meters.nil?
          violations += 1
          violation_seconds += 86_400
        else
          clock += time
          driving += time
          distance += meters
        end
      end
      { visit_ids: rows.map { |row| row[:id] }, feasible: violations.zero?, violations: violations, violation_seconds: violation_seconds,
        distance: distance.round(2), driving: driving.round(2), service: service, waiting: waiting.round(2), total: (clock - @departure).round(2),
        preference_penalty: penalty.round(2), objective: (clock - @departure + penalty).round(2), departure: @departure, finish: clock.round(2), stops: arrivals }
    end

    def score(value)
      [ value[:violations], value[:violation_seconds], value[:objective], value[:driving], value[:distance] ]
    end

    private

    def better?(left, right)
      (score(left) <=> score(right)) == -1
    end

    def nearest(first)
      remaining = stops - [ first ]
      rows = [ first ]
      while remaining.any?
        current = rows.last[:index]
        next_stop = remaining.min_by { |stop| [ durations[current][stop[:index]] || Float::INFINITY, stop[:window_end] || 172_800, stop[:id] ] }
        rows << next_stop
        remaining.delete(next_stop)
      end
      rows
    end

    def insertion
      rows = []
      stops.sort_by { |stop| [ stop[:window_end] || stop[:preferred] || 172_800, stop[:id] ] }.each do |stop|
        alternatives = (0..rows.size).map { |index| rows.dup.insert(index, stop) }
        rows = alternatives.min_by { |candidate| score(evaluate(candidate)) }
      end
      rows
    end

    def improve(rows)
      best = evaluate(rows)
      4.times do
        changed = false
        # First-improvement keeps a strict, reproducible computation budget.
        rows.size.times do |left|
          ((left + 1)...rows.size).each do |right|
            candidates = [ rows[0...left] + rows[left..right].reverse + rows[(right + 1)..], rows.dup.tap { |copy| copy.insert(right, copy.delete_at(left)) }, rows.dup.tap { |copy| copy.insert(left, copy.delete_at(right)) } ]
            candidates.each do |candidate|
              return best if evaluations >= @budget
              value = evaluate(candidate)
              if better?(value, best)
                best, rows, changed = value, candidate, true
              end
            end
          end
        end
        break unless changed
      end
      best
    end
  end
end
