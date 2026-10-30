# Streams

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::


The FIFO form, its commit state, and the lookup API.

(api-streamform)=
## StreamForm

```julia
StreamForm
```

A [`Form`](forms.md#api-form) backed by an Air `Stream{Form}`: a FIFO of forms that supports
blocking `put!`/`take`, an optional bound, timeouts, and `close`. Its contents
are persisted, and it loads lazily by id.

Create one with `StreamForm(db; maxsize, metadata)`; retrieve an existing one
with [`get_stream`](#api-get-stream). In JSON a stream is written `"&<uuid>"`.


```julia
StreamForm(db; maxsize = nothing, pending_commit = false,
           metadata = nothing) -> StreamForm
```

Create a stream form and register its (empty) row for writing. `maxsize` bounds
the number of queued forms (`nothing` leaves it unbounded). Send and receive with
`put!(sf, value)` and `take(sf)`; both accept `timeout` and `token` keywords, and
`close(sf)` ends the stream. `metadata` is the owner/ACL metadata blob.

`pending_commit = true` marks a stream created inside a transaction that has not
committed: read-like operations raise [`UncommittedStream`](#api-uncommittedstream) until
[`mark_committed!`](promises.md#api-mark-committed), and [`mark_aborted!`](promises.md#api-mark-aborted) makes every operation
raise [`AbortedStream`](#api-abortedstream). Writing to a pending stream is allowed.


(api-get-stream)=
## get_stream

```julia
get_stream(db::AbstractDatabase, id::UUID) -> StreamForm
```

The stream form with the given id, cached like [`get_form`](volatile-forms.md#api-get-form).


(api-uncommittedstream)=
## UncommittedStream

```julia
UncommittedStream
```

Raised when a stream created inside a transaction is used before that
transaction commits. See [`StreamForm`](#api-streamform).


(api-abortedstream)=
## AbortedStream

```julia
AbortedStream
```

Raised when a stream whose creating transaction aborted is used.


