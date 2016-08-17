export naturaljoin

## Joins

# Natural Join (Both NDSParse arrays must have the same number of columns, in the same order)

function naturaljoin(left::NDSparse, right::NDSparse, op::Function)
    flush!(left); flush!(right)
    lI = left.index
    rI = right.index
    lD = left.data
    rD = right.data

    ll, rr = length(lI), length(rI)

    # Guess the length of the result
    guess = min(ll, rr)

    # Initialize output array components
    I = Columns(map(c->_sizehint!(similar(c,0), guess), lI.columns))
    data = _sizehint!(similar(lD, typeof(op(lD[1],rD[1])), 0), guess)

    # Match and insert rows
    i = j = 1

    while i <= ll && j <= rr
        lt, rt = lI[i], rI[j]
        c = cmp(lt, rt)
        if c == 0
            push!(I, lt)
            push!(data, op(lD[i], rD[j]))
            i += 1
            j += 1
        elseif c < 0
            i += 1
        else
            j += 1
        end
    end

    # Generate final datastructure
    NDSparse(I, data, presorted=true)
end

map{T,S,D}(f, x::NDSparse{T,D}, y::NDSparse{S,D}) = naturaljoin(x, y, f)

# merge - union join

function count_overlap{D}(I::Columns{D}, J::Columns{D})
    lI, lJ = length(I), length(J)
    i = j = 1
    overlap = 0
    while i <= lI && j <= lJ
        c = rowcmp(I, i, J, j)
        if c == 0
            overlap += 1
            i += 1
            j += 1
        elseif c < 0
            i += 1
        else
            j += 1
        end
    end
    return overlap
end

# assign y into x out-of-place
merge{T,S,D}(x::NDSparse{T,D}, y::NDSparse{S,D}) = (flush!(x);flush!(y); _merge(x, y))
# merge without flush!
function _merge{T,S,D}(x::NDSparse{T,D}, y::NDSparse{S,D})
    I, J = x.index, y.index
    lI, lJ = length(I), length(J)
    n = lI + lJ - count_overlap(I, J)
    K = Columns(map(c->similar(c,n), I.columns))::typeof(I)
    data = similar(x.data, n)
    i = j = 1
    @inbounds for k = 1:n
        if i <= lI && j <= lJ
            c = rowcmp(I, i, J, j)
            if c >= 0
                K[k] = J[j]
                data[k] = y.data[j]
                if c==0; i += 1; end
                j += 1
            else
                K[k] = I[i]
                data[k] = x.data[i]
                i += 1
            end
        elseif i <= lI
            # TODO: copy remaining data columnwise
            K[k] = I[i]
            data[k] = x.data[i]
            i += 1
        elseif j <= lJ
            K[k] = J[j]
            data[k] = y.data[j]
            j += 1
        else
            break
        end
    end
    NDSparse(K, data, presorted=true)
end

# broadcast join - repeat data along a dimension missing from one array

tslice(t::Tuple, I) = ntuple(i->t[I[i]], length(I))

function match_indices(A::NDSparse, B::NDSparse)
    Ap = typeof(A).parameters[2].parameters
    Bp = typeof(B).parameters[2].parameters
    matches = zeros(Int, length(Ap))
    J = IntSet(1:length(Bp))
    for i = 1:length(Ap)
        for j in J
            if Ap[i] == Bp[j]
                matches[i] = j
                delete!(J, j)
                break
            end
        end
    end
    isempty(J) || error("unmatched source indices: $(collect(J))")
    tuple(matches...)
end

function broadcast!(f::Function, A::NDSparse, B::NDSparse, C::NDSparse)
    flush!(A); flush!(B); flush!(C)
    B_inds = match_indices(A, B)
    C_inds = match_indices(A, C)
    all(i->B_inds[i] > 0 || C_inds[i] > 0, 1:ndims(A)) ||
        error("some destination indices are uncovered")
    common = filter(i->B_inds[i] > 0 && C_inds[i] > 0, 1:ndims(A))
    B_common = tslice(B_inds, common)
    C_common = tslice(C_inds, common)
    B_perm = sortperm(Columns(B.index.columns[[B_common...]]))
    C_perm = sortperm(Columns(C.index.columns[[C_common...]]))
    empty!(A)
    m, n = length(B_perm), length(C_perm)
    jlo = klo = 1
    while jlo <= m && klo <= n
        b_common = tslice(B.index[B_perm[jlo]], B_common)
        c_common = tslice(C.index[C_perm[klo]], C_common)
        x = cmp(b_common, c_common)
        x < 0 && (jlo += 1; continue)
        x > 0 && (klo += 1; continue)
        jhi, khi = jlo + 1, klo + 1
        while jhi <= m && tslice(B.index[B_perm[jhi]], B_common) == b_common
            jhi += 1
        end
        while khi <= n && tslice(C.index[C_perm[khi]], C_common) == c_common
            khi += 1
        end
        for ji = jlo:jhi-1
            j = B_perm[ji]
            b_row = B.index[j]
            for ki = klo:khi-1
                k = C_perm[ki]
                c_row = C.index[k]
                vals = ntuple(ndims(A)) do i
                    B_inds[i] > 0 ? b_row[B_inds[i]] : c_row[C_inds[i]]
                end
                push!(A.index, vals)
                push!(A.data, f(B.data[j], C.data[k]))
            end
        end
        jlo, klo = jhi, khi
    end
    order!(A)
end

# TODO: allow B to subsume columns of A as well?

broadcast(f::Function, A::NDSparse, B::NDSparse) = broadcast!(f, similar(A), A, B)

broadcast(f::Function, x::NDSparse, y) = NDSparse(x.index, broadcast(f, x.data, y), presorted=true)
broadcast(f::Function, y, x::NDSparse) = NDSparse(x.index, broadcast(f, y, x.data), presorted=true)