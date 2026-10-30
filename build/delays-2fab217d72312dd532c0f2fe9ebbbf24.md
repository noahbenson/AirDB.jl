# Delays

<!-- review-status: unreviewed -->
:::{warning} Unreviewed content
This page was written with AI assistance and has not been reviewed by a human.
It may contain errors, omissions, or outdated information.
:::


The run-once lazy form and the registry that defines it.

(api-delayform)=
## DelayForm

```julia
DelayForm(type, form)
```

A [`Form`](forms.md#api-form) that computes its value lazily from a serialized form. `type` is
the keyword under which a loader was registered with [`register_delay`](#api-register-delay);
`form` is the serialization, fixed for the delay's life. `d[]` runs the loader
once and memoizes the result, and writing the delay back out never forces it.


```julia
DelayForm(type::Symbol, form::Form) -> DelayForm
```

Create a delay form of the registered type `type`, serialized as `form`. The
loader is run the first time `d[]` is read, and the result is memoized; writing
the delay out never forces it.


(api-register-delay)=
## register_delay

```julia
register_delay(name::Symbol, load_fn)
```

Register a delay type under `name`. `load_fn(form)` computes the delay's value
from its serialization form. Create a delay with `DelayForm(name, form)`.


