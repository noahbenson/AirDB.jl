################################################################################
# api_groups.jl
#
# The curated specification for the generated API reference. `generate_api.jl`
# includes this file; `api_groups()` returns the ordered groups. Every entry is
# a symbol naming a binding in AirDB; the generator resolves it to the
# docstrings registered under `Base.Docs.Binding(AirDB, name)`.
#
# `display` overrides the heading text (default: the name). `signature`
# overrides the leading indented signature block when a docstring has none.
#
# The API surface is every exported name plus the four documented qualified
# functions the guide uses: `sync`, `status`, `load!`, and `close`. Keep the
# entry list in sync with `src/*.jl`; `generate_api.jl --strict` checks it.
#
# MIT License
# Copyright (c) 2020-2026 Noah C. Benson

function api_groups()
    return [
        (slug = "index", title = "API reference", kind = :index, entries = Symbol[]),

        (slug = "configuration", title = "Configuration and lifecycle",
         intro = """
         The configuration a `Database` is built from, the database object itself,
         and the operations that apply to the whole database: waiting for a write
         to become durable, inspecting the writer, and closing it.
         """,
         entries = [
            :DatabaseConfig, :Database, :create_database, :open_database,
            :MemoryDatabase, :sync, :status, :close, :DatabaseError,
            :FormNotFound,
         ]),

        (slug = "forms", title = "Forms",
         intro = """
         The value types: scalar and container forms, the builders that create
         them, and the helpers that classify a leaf.
         """,
         entries = [
            :Form, :FormScalar, :FormContainer, :FormLeaf, :FormValue, :form,
            :to_form, :value, :is_form_representable, :iskeyword, :iswildcard,
         ]),

        (slug = "indexing-and-verbs",
         title = "Updating and verbs",
         intro = """
         The functional updates and the verb helpers that transform a form. The
         transactional form of an update is `setindex!` inside `@tx`; see
         [Transactions and persistence](../transactions/stm.md).
         """,
         entries = [
            :update, Symbol("update!"), :merge_with, :select_keys, :map_values,
            :map_keys, :deep_map, :to_vector, :to_dict,
         ]),

        (slug = "equivalence", title = "Equivalence",
         intro = """
         The type-sensitive equivalence relation and the hash that agrees with
         it. See [Equivalence](../semantics/equivalence.md).
         """,
         entries = [:isequiv, :equivhash]),

        (slug = "json", title = "JSON",
         intro = """
         The textual form used for storage and interchange. See
         [The JSON format](../semantics/json.md).
         """,
         entries = [:to_JSON, :from_JSON]),

        (slug = "volatile-forms", title = "Volatile forms and metadata",
         intro = """
         The database-backed form, the lookup and loading API, and the optional
         owner/ACL metadata and history policy every database-backed kind shares.
         """,
         entries = [
            :VolatileForm, :get_form, :isloaded, Symbol("load!"), :history,
            :metadata, Symbol("set_metadata!"),
         ]),

        (slug = "named-forms", title = "Named forms",
         intro = """
         Stable names for forms, and the alias table that resolves them.
         """,
         entries = [:named_form, Symbol("name_form!"), :named_forms,
                    Symbol("delete_name!")]),

        (slug = "actors", title = "Actors",
         intro = """
         The sequential worker form.
         """,
         entries = [:ActorForm, :get_actor]),

        (slug = "promises", title = "Promises",
         intro = """
         The single-assignment form, its commit state, and the lookup API.
         """,
         entries = [
            :PromiseForm, :get_promise, :UncommittedPromise, :AbortedPromise,
            Symbol("mark_pending_commit!"), Symbol("mark_committed!"),
            Symbol("mark_aborted!"),
         ]),

        (slug = "delays", title = "Delays",
         intro = """
         The run-once lazy form and the registry that defines it.
         """,
         entries = [:DelayForm, :register_delay]),

        (slug = "streams", title = "Streams",
         intro = """
         The FIFO form, its commit state, and the lookup API.
         """,
         entries = [
            :StreamForm, :get_stream, :UncommittedStream, :AbortedStream,
         ]),

        (slug = "externs", title = "Extern types",
         intro = """
         Host-level values: registration, construction, calls, reservations, and
         the form that wraps them. See
         [Extern types](../live/externs-registration.md).
         """,
         entries = [
            :AbstractAirExtern, :FormExtern, :DeadExtern, :ExternAPI,
            :ExternError, :ExternPromise, :register_extern, :get_extern_API,
            :construct, :call, :reserve, :reserve_read,
         ]),

        (slug = "failures", title = "Failures",
         intro = """
         The records a quarantined batch leaves behind, the queries that inspect
         them, and the calls that clear or retry one. See
         [Inspecting failures](../operations/failures-inspection.md).
         """,
         entries = [
            :FailedItem, :FailureRecord, :ReadFailure, :FailedObjectError,
            :write_failures, :failed, Symbol("clear_write_failure!"),
            Symbol("clear_write_failures!"), :read_failures,
            Symbol("clear_read_failures!"), :pending_writes,
         ]),

        (slug = "garbage-collection", title = "Garbage collection",
         intro = """
         The sweep that reclaims rows nothing references any more, and its
         statistics.
         """,
         entries = [Symbol("gc!"), :GCStats]),
    ]
end
