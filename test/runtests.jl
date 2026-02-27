using KhepriIFC
using Test

@testset "KhepriIFC" begin

  @testset "Module exports" begin
    @test isdefined(KhepriIFC, :IFC_backend)
    @test isdefined(KhepriIFC, :ifc)
    @test isdefined(KhepriIFC, :save_ifc)
    @test isdefined(KhepriIFC, :IFCMaterial)
    @test isdefined(KhepriIFC, :ifc_material)
  end

  @testset "Backend type" begin
    @test ifc isa KhepriBase.LocalBackend
    @test backend_name(ifc) == "IFC"
    @test void_ref(ifc) == -1
  end

  @testset "IFCMaterial construction" begin
    mat = ifc_material("TestMat", red=0.8, green=0.2, blue=0.1)
    @test mat.name == "TestMat"
    @test mat.red == 0.8
    @test mat.green == 0.2
    @test mat.blue == 0.1
    @test mat.alpha == 1.0
  end

  # IFC STEP files use UPPERCASE entity names (e.g. IFCPROJECT, IFCWALL)
  @testset "IFC model initialization and save" begin
    backend(ifc)
    delete_all_shapes()

    box(xyz(0, 0, 0), 5, 3, 2)

    tmpfile = tempname() * ".ifc"
    save_ifc(tmpfile)
    @test isfile(tmpfile)

    content = read(tmpfile, String)
    @test startswith(content, "ISO-10303-21")
    @test occursin("IFC4", content)
    @test occursin("IFCPROJECT", content)

    rm(tmpfile)
    delete_all_shapes()
  end

  @testset "Multiple shapes" begin
    backend(ifc)
    delete_all_shapes()

    box(xyz(0, 0, 0), 2, 2, 2)
    cylinder(xyz(5, 0, 0), 1, 3)
    sphere(xyz(10, 0, 0), 2)

    tmpfile = tempname() * ".ifc"
    save_ifc(tmpfile)
    @test isfile(tmpfile)

    content = read(tmpfile, String)
    @test occursin("IFCBUILDINGELEMENTPROXY", content)
    @test occursin("IFCEXTRUDEDAREASOLID", content)

    rm(tmpfile)
    delete_all_shapes()
  end

  @testset "Materials" begin
    backend(ifc)
    delete_all_shapes()

    box(xyz(0, 0, 0), 3, 3, 3, material=material_glass)

    tmpfile = tempname() * ".ifc"
    save_ifc(tmpfile)
    @test isfile(tmpfile)

    content = read(tmpfile, String)
    @test occursin("IFCSURFACESTYLERENDERING", content)
    @test occursin("IFCMATERIAL", content)

    rm(tmpfile)
    delete_all_shapes()
  end

  @testset "BIM wall" begin
    backend(ifc)
    delete_all_shapes()

    wall(path=[xy(0, 0), xy(10, 0)])

    tmpfile = tempname() * ".ifc"
    save_ifc(tmpfile)
    @test isfile(tmpfile)

    content = read(tmpfile, String)
    @test occursin("IFCWALL", content)

    rm(tmpfile)
    delete_all_shapes()
  end

  @testset "BIM slab" begin
    backend(ifc)
    delete_all_shapes()

    slab(region=[xy(0,0), xy(10,0), xy(10,10), xy(0,10)])

    tmpfile = tempname() * ".ifc"
    save_ifc(tmpfile)
    @test isfile(tmpfile)

    content = read(tmpfile, String)
    @test occursin("IFCSLAB", content)

    rm(tmpfile)
    delete_all_shapes()
  end

  @testset "BIM beam and column" begin
    backend(ifc)
    delete_all_shapes()

    beam(xyz(0, 0, 0), 5.0)
    column(xyz(5, 5, 0))

    tmpfile = tempname() * ".ifc"
    save_ifc(tmpfile)
    @test isfile(tmpfile)

    content = read(tmpfile, String)
    @test occursin("IFCBEAM", content)
    @test occursin("IFCCOLUMN", content)

    rm(tmpfile)
    delete_all_shapes()
  end

  @testset "Combined BIM room" begin
    backend(ifc)
    delete_all_shapes()

    wall(path=[xy(0, 0), xy(10, 0)])
    wall(path=[xy(10, 0), xy(10, 5)])
    wall(path=[xy(10, 5), xy(0, 5)])
    wall(path=[xy(0, 5), xy(0, 0)])
    slab(region=[xy(0,0), xy(10,0), xy(10,5), xy(0,5)])

    tmpfile = tempname() * ".ifc"
    save_ifc(tmpfile)
    @test isfile(tmpfile)

    content = read(tmpfile, String)
    @test occursin("IFCWALL", content)
    @test occursin("IFCSLAB", content)
    wall_count = length(collect(eachmatch(r"IFCWALL\(", content)))
    @test wall_count == 4

    rm(tmpfile)
    delete_all_shapes()
  end

  @testset "Units are meters (SI)" begin
    backend(ifc)
    delete_all_shapes()

    box(xyz(0, 0, 0), 1, 1, 1)

    tmpfile = tempname() * ".ifc"
    save_ifc(tmpfile)
    content = read(tmpfile, String)

    # SI length unit without prefix means meters (not millimeters)
    @test !occursin(".MILLI.", content)
    @test occursin("IFCSIUNIT", content)
    @test occursin(".LENGTHUNIT.", content)

    rm(tmpfile)
    delete_all_shapes()
  end

  @testset "Multiple storeys" begin
    backend(ifc)
    delete_all_shapes()

    # Walls at ground level (0m) and upper level (3m)
    lvl0 = level(0)
    lvl3 = level(3)
    lvl6 = level(6)
    wall(path=[xy(0, 0), xy(5, 0)], bottom_level=lvl0, top_level=lvl3)
    wall(path=[xy(0, 0), xy(5, 0)], bottom_level=lvl3, top_level=lvl6)

    tmpfile = tempname() * ".ifc"
    save_ifc(tmpfile)
    content = read(tmpfile, String)

    storey_count = length(collect(eachmatch(r"IFCBUILDINGSTOREY\(", content)))
    @test storey_count >= 2
    @test occursin("Ground Floor", content)

    rm(tmpfile)
    delete_all_shapes()
  end

  @testset "Property sets" begin
    backend(ifc)
    delete_all_shapes()

    wall(path=[xy(0, 0), xy(10, 0)])
    slab(region=[xy(0,0), xy(10,0), xy(10,10), xy(0,10)])
    beam(xyz(0, 0, 0), 5.0)
    column(xyz(5, 5, 0))

    tmpfile = tempname() * ".ifc"
    save_ifc(tmpfile)
    content = read(tmpfile, String)

    @test occursin("IFCPROPERTYSET", content)
    @test occursin("Pset_WallCommon", content)
    @test occursin("Pset_SlabCommon", content)
    @test occursin("Pset_BeamCommon", content)
    @test occursin("Pset_ColumnCommon", content)
    @test occursin("IsExternal", content)
    @test occursin("LoadBearing", content)

    rm(tmpfile)
    delete_all_shapes()
  end

  @testset "Wall with door" begin
    backend(ifc)
    delete_all_shapes()

    let w = wall(path=[xy(0, 0), xy(10, 0)])
      add_door(w, xy(2, 0))
    end

    tmpfile = tempname() * ".ifc"
    save_ifc(tmpfile)
    content = read(tmpfile, String)

    @test occursin("IFCWALL", content)
    @test occursin("IFCOPENINGELEMENT", content)
    @test occursin("IFCDOOR", content)
    @test occursin("IFCRELVOIDSELEMENT", content)
    @test occursin("IFCRELFILLSELEMENT", content)
    @test occursin("Pset_DoorCommon", content)

    rm(tmpfile)
    delete_all_shapes()
  end

  @testset "Wall with window" begin
    backend(ifc)
    delete_all_shapes()

    let w = wall(path=[xy(0, 0), xy(10, 0)])
      add_window(w, xy(3, 1))
    end

    tmpfile = tempname() * ".ifc"
    save_ifc(tmpfile)
    content = read(tmpfile, String)

    @test occursin("IFCWALL", content)
    @test occursin("IFCOPENINGELEMENT", content)
    @test occursin("IFCWINDOW", content)
    @test occursin("IFCRELVOIDSELEMENT", content)
    @test occursin("IFCRELFILLSELEMENT", content)
    @test occursin("Pset_WindowCommon", content)

    rm(tmpfile)
    delete_all_shapes()
  end

  @testset "Wall with door and window" begin
    backend(ifc)
    delete_all_shapes()

    let w = wall(path=[xy(0, 0), xy(10, 0)])
      add_door(w, xy(1, 0))
      add_window(w, xy(5, 1))
    end

    tmpfile = tempname() * ".ifc"
    save_ifc(tmpfile)
    content = read(tmpfile, String)

    @test occursin("IFCWALL", content)
    @test occursin("IFCDOOR", content)
    @test occursin("IFCWINDOW", content)
    opening_count = length(collect(eachmatch(r"IFCOPENINGELEMENT\(", content)))
    @test opening_count == 2

    rm(tmpfile)
    delete_all_shapes()
  end

  @testset "BIM ceiling" begin
    backend(ifc)
    delete_all_shapes()

    ceiling(region=[xy(0,0), xy(10,0), xy(10,8), xy(0,8)], level=level(3))

    tmpfile = tempname() * ".ifc"
    save_ifc(tmpfile)
    @test isfile(tmpfile)

    content = read(tmpfile, String)
    @test occursin("IFCCOVERING", content)
    @test occursin("Pset_CoveringCommon", content)

    rm(tmpfile)
    delete_all_shapes()
  end

  @testset "BIM stair" begin
    backend(ifc)
    delete_all_shapes()

    stair(xy(0,0), vy(1), level(0), level(3))

    tmpfile = tempname() * ".ifc"
    save_ifc(tmpfile)
    @test isfile(tmpfile)

    content = read(tmpfile, String)
    @test occursin("IFCSTAIRFLIGHT", content)
    @test occursin("Pset_StairFlightCommon", content)

    rm(tmpfile)
    delete_all_shapes()
  end

  @testset "BIM spiral stair" begin
    backend(ifc)
    delete_all_shapes()

    spiral_stair(xy(0,0), 2.0, 0, 2*pi, true, level(0), level(3))

    tmpfile = tempname() * ".ifc"
    save_ifc(tmpfile)
    @test isfile(tmpfile)

    content = read(tmpfile, String)
    @test occursin("IFCSTAIRFLIGHT", content)

    rm(tmpfile)
    delete_all_shapes()
  end

  @testset "BIM stair landing" begin
    backend(ifc)
    delete_all_shapes()

    stair_landing(region=[xy(0,0), xy(2,0), xy(2,1), xy(0,1)], level=level(3))

    tmpfile = tempname() * ".ifc"
    save_ifc(tmpfile)
    @test isfile(tmpfile)

    content = read(tmpfile, String)
    @test occursin("IFCSLAB", content)
    @test occursin(".LANDING.", content)

    rm(tmpfile)
    delete_all_shapes()
  end

  @testset "BIM ramp" begin
    backend(ifc)
    delete_all_shapes()

    ramp(xy(0,0), xy(5,0), bottom_level=level(0), top_level=level(1))

    tmpfile = tempname() * ".ifc"
    save_ifc(tmpfile)
    @test isfile(tmpfile)

    content = read(tmpfile, String)
    @test occursin("IFCRAMPFLIGHT", content)
    @test occursin("Pset_RampFlightCommon", content)

    rm(tmpfile)
    delete_all_shapes()
  end

  @testset "BIM railing" begin
    backend(ifc)
    delete_all_shapes()

    railing(path=[xy(0,0), xy(0,5)], level=level(0))

    tmpfile = tempname() * ".ifc"
    save_ifc(tmpfile)
    @test isfile(tmpfile)

    content = read(tmpfile, String)
    @test occursin("IFCRAILING", content)
    @test occursin("Pset_RailingCommon", content)

    rm(tmpfile)
    delete_all_shapes()
  end

  @testset "BIM stairwell" begin
    backend(ifc)
    delete_all_shapes()

    lvl0 = level(0)
    lvl3 = level(3)
    stair(xy(0,0), vy(1), lvl0, lvl3)
    stair_landing(region=[xy(0,0), xy(2,0), xy(2,1), xy(0,1)], level=lvl3)
    railing(path=[xy(0,0), xy(0,5)], level=lvl0)
    railing(path=[xy(2,0), xy(2,5)], level=lvl0)

    tmpfile = tempname() * ".ifc"
    save_ifc(tmpfile)
    @test isfile(tmpfile)

    content = read(tmpfile, String)
    @test occursin("IFCSTAIRFLIGHT", content)
    @test occursin("IFCSLAB", content)
    @test occursin("IFCRAILING", content)

    rm(tmpfile)
    delete_all_shapes()
  end
end
