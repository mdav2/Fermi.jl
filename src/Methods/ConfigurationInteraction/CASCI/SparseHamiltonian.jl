using Combinatorics
using SparseArrays
using ArnoldiMethod

function CASCI{T}(Alg::SparseHamiltonian) where T <: AbstractFloat

    @output "Getting molecule...\n"
    molecule = Molecule()
    @output "Computing AO Integrals...\n"
    #aoint = ConventionalAOIntegrals()

    @output "Calling RHF module...\n"
    refwfn = Fermi.HartreeFock.RHF(molecule)
    ints = refwfn.ints

    @output "Transforming Integrals for CAS computation...\n"
    # Read options
    frozen = Fermi.CurrentOptions["cas_frozen"]

    nmo = refwfn.ndocc + refwfn.nvir

    act_elec = 2*(refwfn.ndocc - frozen)

    if act_elec < 0
        error("\nInvalid number of frozen orbitals ($frozen) for $(2*refwfn.ndocc) electrons.")
    end

    # Active = -1 means FCI, with frozen
    if Fermi.CurrentOptions["cas_active"] == -1
        active = nmo - frozen
    else
        active = Fermi.CurrentOptions["cas_active"]
    end

    if active ≤ act_elec/2
        error("\nNumber of active orbitals ($active) too small for $(act_elec) active electrons")
    end

    if active+frozen > nmo
        error("\nNumber of active ($active) and frozen orbitals ($frozen) greater than number of orbitals ($nmo)")
    end

    s = 1:(frozen+active)
    h = T.(Fermi.Integrals.transform_fock(ints["T"] + ints["V"], ints.orbs["FU"][s], ints.orbs["FU"][s]))
    V = T.(Fermi.Integrals.transform_eri(ints["μ"], ints.orbs["FU"][s], ints.orbs["FU"][s], ints.orbs["FU"][s], ints.orbs["FU"][s]))

    aoint = nothing
    CASCI{T}(refwfn, h, V, frozen, act_elec, active, Alg)
end

function CASCI{T}(refwfn::Fermi.HartreeFock.RHF, h::Array{T,2}, V::Array{T,4}, frozen::Int, act_elec::Int, active::Int, Alg::SparseHamiltonian) where T <: AbstractFloat

    # Print intro
    Fermi.ConfigurationInteraction.print_header()
    @output "\n    • Computing FCI with the SparseMatrix algorithm.\n\n"


    nroot = Fermi.CurrentOptions["cas_nroot"]

    @output "\n →  ACTIVE SPACE\n"
    @output "Frozen Orbitals:  {:3d}\n" frozen
    @output "Active Electrons: {:3d}\n" act_elec
    @output "Active Orbitals:  {:3d}\n" active
    
    @output "\nGenerating determinants ..."
    t = @elapsed begin
        dets = get_determinants(act_elec, active, frozen)
        Ndets = length(dets)
    end
    
    @output " done in {} seconds.\n" t
    @output "\nNumber of Determinants: {:10d}\n" Ndets

    @output "\nBuilding Sparse Hamiltonian..."

    t = @elapsed H = get_sparse_hamiltonian_matrix(dets, h, V, Fermi.CurrentOptions["cas_cutoff"])
    @output " done in {:5.5f} seconds.\n" t
    @output "Hamiltonian Matrix size: {:10.3f} Mb\n" Base.summarysize(H)/10^6

    @output "Diagonalizing Hamiltonian for {:3d} eigenvalues..." nroot
    t = @elapsed begin
        decomp, history = partialschur(H, nev=nroot, tol=10^-12, which=LM())
        λ, ϕ = partialeigen(decomp)
    end
    @output " done in {:5.5f} seconds.\n" t
    @output "\n Final FCI Energy: {:15.10f}\n" λ[1]+refwfn.molecule.Vnuc

    # Sort dets by importance
    C = ϕ[:,1]
    sp = sortperm(abs.(ϕ[:,1]), rev=true)
    C = ϕ[:,1][sp]
    dets = dets[sp]

    @output "\n • Most important determinants:\n\n"

    for i in 1:50
        @output "{:15.5f}      {}\n" C[i]  detstring(dets[i], frozen+active)
    end
    @output "\n"
    return CASCI{T}(refwfn, λ[1]+T(refwfn.molecule.Vnuc), dets, C)
end

function get_determinants(Ne::Int, No::Int, nfrozen::Int)

    Nae = Int(Ne/2)
    occ_string = repeat('1', nfrozen)

    zeroth = repeat('1', Nae)*repeat('0', No-Nae)

    perms = multiset_permutations(zeroth, length(zeroth))

    dets = [Determinant[] for i = 1:Threads.nthreads()]
    @sync for αstring in perms
        Threads.@spawn begin
        for βstring in perms
            α = occ_string*join(αstring)
            β = occ_string*join(βstring)
            _det = Determinant(α, β)
            push!(dets[Threads.threadid()], _det)
        end
        end #Threads.@spawn
    end

    dets = vcat(dets...)
    # Determinant list is sorted by its excitation level w.r.t the first determinant (normally HF)
    #sort!(dets, by=d->excitation_level(dets[1], d))

    return dets
end

function get_sparse_hamiltonian_matrix(dets::Array{Determinant,1}, h::Array{T,2}, V::Array{T,4}, tol::Float64) where T <: AbstractFloat

    Ndets = length(dets)
    Nα = sum(αlist(dets[1]))
    Nβ = sum(αlist(dets[1]))

    αind = [Array{Int64,1}(undef,Nα) for i = 1:Threads.nthreads()]
    βind = [Array{Int64,1}(undef,Nβ) for i = 1:Threads.nthreads()]
    vals = [T[] for i = 1:Threads.nthreads()]
    ivals = [Int64[] for i = 1:Threads.nthreads()]
    jvals = [Int64[] for i = 1:Threads.nthreads()]

    @sync for i in 1:Ndets
        Threads.@spawn begin
        D1 = dets[i]
        αindex!(D1, αind[Threads.threadid()])
        βindex!(D1, βind[Threads.threadid()])
        elem = 0.0
        for j in i:Ndets
            D2 = dets[j]
            αexc = αexcitation_level(D1,D2)
            βexc = βexcitation_level(D1,D2)
            el = αexc + βexc
            if el > 2
                continue 
            elseif el == 2
                elem = Hd2(D1, D2, V, αexc)
            elseif el == 1
                elem = Hd1(αind[Threads.threadid()], βind[Threads.threadid()], D1, D2, h, V, αexc)
            else
                elem = Hd0(αind[Threads.threadid()], βind[Threads.threadid()], h, V)
            end
            if abs(elem) > tol
                push!(vals[Threads.threadid()], elem)
                push!(ivals[Threads.threadid()], i)
                push!(jvals[Threads.threadid()], j)
            end
        end
    end #Threads.@spawn
    end

    ivals = vcat(ivals...)
    jvals = vcat(jvals...)
    vals  = vcat(vals...)
    return Symmetric(sparse(ivals, jvals, vals))
end
