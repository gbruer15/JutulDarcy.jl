function unpack_val(::Val{X}) where X
    return X
end

const DECK_SPLIT_REGEX = r"[ \t,]+"

function read_record(f; fix = true)
    split_lines = Vector{String}()
    active = true
    while !eof(f) && active
        line = readline(f)
        cpos = findfirst("--", line)
        if !isnothing(cpos)
            line = line[1:(first(cpos)-1)]
        end
        line = strip(line)
        if !startswith(line, "--")
            if contains(line, '/')
                # TODO: Think this is OK for parsing ASCII.
                ix = findfirst('/', line)
                line = line[1:ix-1]
                active = false
            end
            if length(line) > 0
                push!(split_lines, line)
            end
        end
    end
    return split_lines
end

function keyword_start(line)
    if isnothing(match(r"^\s*--", line))
        m = match(r"\w+", line)
        if m === nothing
            return nothing
        else
            return Symbol(uppercase(m.match))
        end
    else
        return nothing
    end
end

function parse_defaulted_group_well(f, defaults, wells, namepos = 1)
    out = []
    line = read_record(f)
    while length(line) > 0
        parsed = parse_defaulted_line(line, defaults)
        name = parsed[namepos]
        if occursin('*', name) || occursin('?', name)
            re = Regex(replace(name, "*" => ".*", "?" => "."))
            for wname in keys(wells)
                if occursin(re, wname)
                    replaced_parsed = copy(parsed)
                    replaced_parsed[namepos] = wname
                    push!(out, replaced_parsed)
                end
            end
        else
            push!(out, parsed)
        end
        line = read_record(f)
    end
    return out
end

function parse_defaulted_group(f, defaults)
    out = []
    line = read_record(f)
    while length(line) > 0
        parsed = parse_defaulted_line(line, defaults)
        push!(out, parsed)
        line = read_record(f)
    end
    return out
end

function parse_defaulted_line(lines::String, defaults; kwarg...)
    return parse_defaulted_line([lines], defaults; kwarg...)
end

function parse_defaulted_line(lines, defaults; required_num = 0, keyword = "")
    out = similar(defaults, 0)
    sizehint!(out, length(defaults))
    pos = 1
    for line in lines
        line = replace_quotes(line)
        lsplit = split(strip(line), DECK_SPLIT_REGEX)
        for s in lsplit
            if length(s) == 0
                continue
            end
            default = defaults[pos]
            is_num = default isa Real
            if is_num && occursin('*', s) && !startswith(s, '\'') # Could be inside a string for wildcard matching
                if s == "*"
                    num_defaulted = 1
                else
                    parse_wildcard = match(r"\d+\*", s)
                    if isnothing(parse_wildcard)
                        error("Unable to parse string for * expansion: $s")
                    end
                    num_defaulted = Parsers.parse(Int, parse_wildcard.match[1:end-1])
                end
                for i in 1:num_defaulted
                    push!(out, defaults[pos])
                    pos += 1
                end
            else
                if default isa String
                    converted = strip(s, [' ', '\''])
                else
                    T = typeof(default)
                    converted = Parsers.tryparse(T, s)
                    if isnothing(converted)
                        converted = T.(Parsers.tryparse(Float64, s))
                    end
                end
                push!(out, converted)
                pos += 1
            end
        end
    end
    n = length(defaults)
    n_out = length(out)
    if required_num > n
        error("Bad record: $required_num entries required for keyword $keyword, but only $n records were present.")
    end
    pos = n_out + 1
    if pos < n + 1
        for i in pos:n
            push!(out, defaults[i])
        end
    end
    return out
end

##

function parse_deck_matrix(f, T = Float64)
    # TODO: This is probably a bad way to do large numerical datasets.
    rec = read_record(f)
    split_lines = preprocess_delim_records(rec)
    data = Vector{T}()
    n = -1
    for seg in split_lines
        m = length(seg)
        if m == 0
            continue
        elseif n == -1
            n = m
        else
            @assert m == n "Expected $n was $m"
        end
        for d in seg
            push!(data, parse(T, d))
        end
    end
    if length(data) == 0
        out = missing
    else
        out = reshape(data, n, length(data) ÷ n)'
    end
    return out
end

function preprocess_delim_records(split_lines)
    # Strip end whitespace
    split_lines = map(strip, split_lines)
    # Remove comments
    filter!(x -> !startswith(x, "--"), split_lines)
    # Split into entries (could be whitespace + a comma anywhere in between)
    split_rec = map(x -> split(x, r"\s*,?\s+"), split_lines)
    # Remove entries
    for recs in split_rec
        filter!(x -> length(x) > 0, recs)
    end
    return split_rec
end

function parse_deck_vector(f, T = Float64)
    # TODO: Speed up.
    rec = read_record(f)
    record_lines = preprocess_delim_records(rec)
    n = length(record_lines)
    out = Vector{T}()
    sizehint!(out, n)
    for split_rec in record_lines
        for el in split_rec
            if occursin('*', el)
                n_rep, el = split(el, '*')
                n_rep = parse(Int, n_rep)
            else
                n_rep = 1
            end
            parsed = parse(T, el)::T
            for i in 1:n_rep
                push!(out, parsed)
            end
        end
    end
    return out
end

function skip_record(f)
    rec = read_record(f)
    while length(rec) > 0
        rec = read_record(f)
    end
end

function skip_records(f, n)
    for i = 1:n
        rec = read_record(f)
    end
end

function parse_grid_vector(f, dims, T = Float64)
    v = parse_deck_vector(f, T)
    return reshape(v, dims)
end

function parse_saturation_table(f, outer_data)
    ns = number_of_tables(outer_data, :saturation)
    return parse_region_matrix_table(f, ns)
end

function parse_dead_pvt_table(f, outer_data)
    np = number_of_tables(outer_data, :pvt)
    return parse_region_matrix_table(f, np)
end

function parse_live_pvt_table(f, outer_data)
    nreg = number_of_tables(outer_data, :pvt)
    out = []
    for i = 1:nreg
        current = Vector{Vector{Float64}}()
        while true
            next = parse_deck_vector(f)
            if length(next) == 0
                break
            end
            push!(current, next)
        end
        push!(out, restructure_pvt_table(current))
    end
    return out
end

function restructure_pvt_table(tab)
    nvals_per_rec = 3
    function record_length(x)
        # Actual number of records: 1 key value + nrec*N entries. Return N.
        return (length(x) - 1) ÷ nvals_per_rec
    end
    @assert record_length(last(tab)) > 1
    nrecords = length(tab)
    keys = map(first, tab)
    current = 1
    for tab_ix in eachindex(tab)
        rec = tab[tab_ix]
        interpolate_missing_usat!(tab, tab_ix, record_length, nvals_per_rec)
    end
    # Generate final table
    ntab = sum(record_length, tab)
    data = zeros(ntab, nvals_per_rec)
    for tab_ix in eachindex(tab)
        rec = tab[tab_ix]
        for i in 1:record_length(rec)
            for j in 1:nvals_per_rec
                linear_ix = (i-1)*nvals_per_rec + j + 1
                data[current, j] = rec[linear_ix]
            end
            current += 1
        end
    end

    # Generate pos
    pos = Int[1]
    sizehint!(pos, nrecords+1)
    for rec in tab
        push!(pos, pos[end] + record_length(rec))
    end
    return Dict("data" => data, "key" => keys, "pos" => pos)
end

function interpolate_missing_usat!(tab, tab_ix, record_length, nvals_per_rec)
    rec = tab[tab_ix]
    if record_length(rec) == 1
        @assert nvals_per_rec == 3
        next_rec = missing
        for j in (tab_ix):length(tab)
            if record_length(tab[j]) > 1
                next_rec = tab[j]
                break
            end
        end
        @assert record_length(rec) == 1
        next_rec_length = record_length(next_rec)
        sizehint!(rec, 1 + nvals_per_rec*next_rec_length)

        get_index(major, minor) = nvals_per_rec*(major-1) + minor + 1
        pressure(x, idx) = x[get_index(idx, 1)]
        B(x, idx) = x[get_index(idx, 2)]
        viscosity(x, idx) = x[get_index(idx, 3)]

        function constant_comp_interp(F, F_r, F_l)
            # So that dF/dp * F = constant over the pair of points extrapolated from F
            w = 2.0*(F_l - F_r)/(F_l + F_r)
            return F*(1.0 + w/2.0)/(1.0 - w/2.0)
        end
        @assert !ismissing(next_rec) "Final table must be saturated."

        for idx in 2:next_rec_length
            # Each of these gets added as new unsaturated points
            p_0 = pressure(rec, idx - 1)
            p_l = pressure(next_rec, idx - 1)
            p_r = pressure(next_rec, idx)

            mu_0 = viscosity(rec, idx - 1)
            mu_l = viscosity(next_rec, idx - 1)
            mu_r = viscosity(next_rec, idx)

            B_0 = B(rec, idx - 1)
            B_l = B(next_rec, idx - 1)
            B_r = B(next_rec, idx)

            p_next = p_0 + p_r - p_l
            B_next = constant_comp_interp(B_0, B_l, B_r)
            mu_next = constant_comp_interp(mu_0, mu_l, mu_r)

            push!(rec, p_next)
            push!(rec, B_next)
            push!(rec, mu_next)
        end
    end
    return tab
end

function parse_region_matrix_table(f, nreg)
    out = []
    for i = 1:nreg
        next = parse_deck_matrix(f)
        if ismissing(next)
            if length(out) == 0
                error("First region table cannot be defaulted.")
            end
            next = copy(out[end])
        end
        push!(out, next)
    end
    return out
end

function parse_keyword!(data, outer_data, units, cfg, f, v::Val{T}) where T
    # Keywords where we read a single record and don't do anything proper
    skip_kw = [
        :PETOPTS,
        :PARALLEL,
        :VECTABLE,
        :MULTSAVE
        ]
    skip_kw_with_warn = Symbol[
        :SATOPTS,
        :EQLOPTS,
        :TRACERS,
        :PIMTDIMS,
        :OPTIONS
    ]
    # Single word keywords are trivial to parse, just set a true flag.
    single_word_kw = [
            :MULTOUT,
            :NOSIM,
            :NONNC,
            :NEWTRAN
            ]
    # Keywords that are a single record where we should warn
    single_word_kw_with_warn = Symbol[

    ]
    if T in skip_kw
        data["$T"] = read_record(f)
    elseif T in skip_kw_with_warn
        parser_message(cfg, outer_data, "$T", PARSER_MISSING_SUPPORT)
        data["$T"] = read_record(f)
    elseif T in single_word_kw
        data["$T"] = true
    elseif T in single_word_kw_with_warn
        parser_message(cfg, outer_data, "$T", PARSER_JUTULDARCY_MISSING_SUPPORT)
        data["$T"] = true
    else
        error("Unhandled keyword $T encountered.")
    end
end

function next_keyword!(f)
    m = nothing
    while isnothing(m) && !eof(f)
        line = readline(f)
        m = keyword_start(line)
    end
    return m
end

function number_of_tables(outer_data, t::Symbol)
    rs = outer_data["RUNSPEC"]
    if haskey(rs, "TABDIMS")
        td = rs["TABDIMS"]
    else
        td = [1 1]
    end
    if t == :saturation
        return td[1]
    elseif t == :pvt
        return td[2]
    elseif t == :equil
        if haskey(rs, "EQLDIMS")
            return rs["EQLDIMS"][1]
        else
            return 1
        end
    else
        error(":$t is not known")
    end
end

function compositional_number_of_components(outer_data)
    return outer_data["RUNSPEC"]["COMPS"]
end

function table_region(outer_data, t::Symbol; active = nothing)
    num = number_of_tables(outer_data, t)
    if num == 1
        dim = outer_data["GRID"]["cartDims"]
        D = ones(Int, prod(dim))
    else
        reg = outer_data["REGIONS"]

        function get_or_default(k)
            if haskey(reg, k)
                return vec(reg[k])
            else
                dim = outer_data["GRID"]["cartDims"]
                return ones(Int, prod(dim))
            end
        end
    
        if t == :saturation
            d = get_or_default("SATNUM")
        elseif t == :pvt
            d = get_or_default("PVTNUM")
        elseif t == :equil
            d = get_or_default("EQLNUM")
        else
            error(":$t is not known")
        end
        D = vec(d)
    end
    if !isnothing(active)
        D = D[active]
    end
    return D
end

function clean_include_path(basedir, include_file_name)
    include_file_name = strip(include_file_name)
    include_file_name = replace(include_file_name, "./" => "")
    include_file_name = replace(include_file_name, "'" => "")
    include_path = joinpath(basedir, include_file_name)
    return include_path
end

function get_section(outer_data, name::Symbol)
    s = "$name"
    is_sched = name == :SCHEDULE
    outer_data["CURRENT_SECTION"] = name
    T = OrderedDict{String, Any}
    if is_sched
        if !haskey(outer_data, s)
            outer_data[s] = Dict(
                "STEPS" => [T()],
                "WELSPECS" => T(),
                "COMPORD" => T()
            )
        end
        out = outer_data[s]["STEPS"][end]
    else
        if !haskey(outer_data, s)
            outer_data[s] = T()
        end
        out = outer_data[s]
    end
    return out
end

function new_section(outer_data, name::Symbol)
    data = get_section(outer_data, name)
    return data
end

function replace_quotes(str::String)
    if '\'' in str
        v = collect(str)
        in_quote = false
        new_char = Char[]
        for i in eachindex(v)
            v_i = v[i]
            if v_i == '\''
                in_quote = !in_quote
            elseif in_quote && v_i == ' '
                # TODO: Is this a safe replacement?
                push!(new_char, '-')
            else
                push!(new_char, v_i)
            end
        end
        str = String(new_char)
    end
    return str
end

function push_and_create!(data, k, vals, T = Any)
    if !haskey(data, k)
        data[k] = T[]
    end
    out = data[k]
    for v in vals
        v::T
        push!(out, v)
    end
    return data
end
