# KhepriIFC tests — IFC file output via Python ifcopenshell
#
# Tests cover module loading, pure-Julia helpers, the IFC struct,
# and property macros. Actual IFC file operations require the
# Python ifcopenshell package.

using KhepriIFC
using Test

@testset "KhepriIFC.jl" begin

  @testset "Module loading" begin
    @test isdefined(KhepriIFC, :IFC)
    @test isdefined(KhepriIFC, :new_building)
    @test isdefined(KhepriIFC, :new_storey)
  end

  @testset "None constant" begin
    @test KhepriIFC.None === nothing
  end

  @testset "name_method function" begin
    # Symbol input: titlecase + remove underscores
    name, method = KhepriIFC.name_method(:global_id)
    @test name === :global_id
    @test method === :GlobalId

    name2, method2 = KhepriIFC.name_method(:name)
    @test name2 === :name
    @test method2 === :Name
  end

  @testset "IFC struct fields" begin
    @test fieldnames(KhepriIFC.IFC) ==
          (:file, :owner_history, :project, :context,
           :site_placement, :site, :building_placement, :building)
  end

  @testset "Property macros exist" begin
    @test isdefined(KhepriIFC, Symbol("@def_rw_property"))
    @test isdefined(KhepriIFC, Symbol("@def_ro_property"))
  end
end
