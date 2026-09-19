defmodule SymphonyElixir.Dispatch.Snapshot do
  @moduledoc "Complete tracker observation. Validation is not eligibility or permission to launch."
  alias SymphonyElixir.Tracker.Issue
  defstruct [:scope, :canonical_issue_id, :issue, :child_ids, :repository, :route, :observed_at_ms, version: 1, complete: false]

  @type t :: %__MODULE__{
          version: 1,
          scope: {String.t(), String.t()} | nil,
          canonical_issue_id: String.t() | nil,
          issue: Issue.t() | nil,
          child_ids: [String.t()] | nil,
          repository: String.t() | nil,
          route: String.t() | nil,
          observed_at_ms: non_neg_integer() | nil,
          complete: boolean()
        }
end

defmodule SymphonyElixir.Dispatch.Worker do
  @moduledoc "Trusted configured host observation; never infer OS from the host alias."
  defstruct [:id, :os, :available, :slots, :observed_at_ms, version: 1]

  @type t :: %__MODULE__{
          version: 1,
          id: String.t() | nil,
          os: :linux | :macos | :windows | :unknown | nil,
          available: boolean() | nil,
          slots: non_neg_integer() | nil,
          observed_at_ms: non_neg_integer() | nil
        }
end

defmodule SymphonyElixir.Dispatch.Attempt do
  @moduledoc "Capacity observation and resume affinity; does not represent an acquired lease."
  defstruct [:role, :active_writers, :deliveries, :regression, :observed_at_ms, :preferred_host, :integration_owner, version: 1, complete: false]
  @type delivery_id :: {String.t(), String.t()}
  @type t :: %__MODULE__{
          version: 1,
          role: :writer | :integration | :repair | nil,
          active_writers: non_neg_integer() | nil,
          deliveries: [delivery_id()] | nil,
          regression: boolean() | nil,
          observed_at_ms: non_neg_integer() | nil,
          preferred_host: String.t() | nil,
          integration_owner: String.t() | nil,
          complete: boolean()
        }
end
