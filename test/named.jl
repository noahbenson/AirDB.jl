@testset "named forms" begin
    cfg = _TEST_CFG
    db = create_database(cfg; overwrite = true)
    conn = _connect(cfg)
    try
        @testset "create and retrieve" begin
            # the default, create = false, raises when the name is missing
            @test_throws ArgumentError named_form(db, "root")

            root = named_form(db, "root"; create = true, value = form(version = 1))
            AirDB.sync(db)
            @test root isa VolatileForm
            @test named_form(db, "root") === root
            @test named_form(db, :root) === root                 # Symbol and String agree
            @test named_form(db, "root"; create = nothing) === root

            # the named form is a real form, with its own rows ...
            @test _current_version(conn, root.id) == 1
            @test _history(conn, root.id) == [(1, 1)]
            # ... and the alias row points at it
            r = LibPQ.execute(conn, "SELECT form_id::text FROM form_name WHERE name = 'root'")
            @test String(first(r)[1]) == string(root.id)
        end

        @testset "create = true raises when the name is taken" begin
            @test_throws ArgumentError named_form(db, "root"; create = true)
            @test_throws ArgumentError named_form(db, :root; create = true)
        end

        @testset "create = nothing never raises" begin
            @test named_form(db, "nope"; create = nothing) === nothing
            @test named_form(db, :nope; create = nothing) === nothing
            @test_throws ArgumentError named_form(db, "nope")    # default create = false
        end

        @testset "initial values" begin
            # a Form is used as-is
            a = named_form(db, "a"; create = true, value = form(x = 1))
            @test a[] == form(x = 1)
            # a plain value is wrapped
            b = named_form(db, "b"; create = true, value = 5)
            @test b[] == Form(5)
            # no value gives an empty form
            c = named_form(db, "c"; create = true)
            @test c[] == form()
            # a VolatileForm is aliased, not copied
            d = VolatileForm(db, n = 1)
            e = named_form(db, "d"; create = true, value = d)
            @test e === d
            @test named_form(db, "d") === d
            AirDB.sync(db)
            @test _current_version(conn, e.id) == 1
        end

        @testset "name_form! overwrites" begin
            x = VolatileForm(db, tag = "x")
            y = VolatileForm(db, tag = "y")
            name_form!(db, "slot", x)
            @test named_form(db, "slot") === x
            name_form!(db, "slot", y)
            @test named_form(db, "slot") === y
            AirDB.sync(db)
            r = LibPQ.execute(conn, "SELECT form_id::text FROM form_name WHERE name = 'slot'")
            @test String(first(r)[1]) == string(y.id)
        end

        @testset "the whole table" begin
            names = named_forms(db)
            @test names isa PDict{String,VolatileForm}
            @test names["root"] === named_form(db, "root")
            @test haskey(names, "d")
            @test length(names) >= 5
        end

        @testset "registration is transactional" begin
            # a registration in a transaction that aborts is discarded ...
            n0 = length(named_forms(db))
            try
                @tx begin
                    named_form(db, "temp"; create = true)
                    error("abort")
                end
            catch
            end
            @test named_form(db, "temp"; create = nothing) === nothing
            @test length(named_forms(db)) == n0

            # ... and one in a committed transaction is kept, and visible within it
            seen = Ref{Any}(nothing)
            @tx begin
                v = named_form(db, "committed"; create = true, value = form(n = 1))
                seen[] = named_form(db, "committed")
            end
            AirDB.sync(db)
            @test seen[] !== nothing
            @test seen[] === named_form(db, "committed")
            @test value(named_form(db, "committed")[:n]) == 1

            # name_form! is transactional too
            f = VolatileForm(db, tag = "f")
            @tx name_form!(db, "renamed", f)
            AirDB.sync(db)
            @test named_form(db, "renamed") === f
        end

        @testset "concurrent creates" begin
            n = 20
            @sync for i in 1:n
                Threads.@spawn named_form(db, "c$i"; create = true, value = form(i = i))
            end
            AirDB.sync(db)
            names = named_forms(db)
            @test all(haskey(names, "c$i") for i in 1:n)
            @test all(value(named_form(db, "c$i")[:i]) == i for i in 1:n)
        end

        @testset "across connections" begin
            id = named_form(db, "root").id
            close(db)
            db = open_database(cfg)
            r = named_form(db, "root")
            @test r !== nothing
            @test r.id == id
            @test value(r[:version]) == 1
            # the whole table is loaded at open
            @test haskey(named_forms(db), "root")
        end
    finally
        close(conn)
        close(db)
    end
end
