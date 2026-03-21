#=
A backend for IFC (Industry Foundation Classes) file generation.

Uses PythonCall + IfcOpenShell for IFC entity creation and file output.
Targets IFC4 schema.
=#

import PythonCall: Py, pynew, pybuiltins, pyimport, pylist, pydict, pycopy!
import KhepriBase: slab_family_thickness, slab_family_elevation,
                   ceiling_family_thickness, ceiling_family_elevation,
                   level_height, family_profile, r_thickness, l_thickness,
                   Wall, Slab, Beam, Column, Door, Window

export IFC_backend,
       ifc,
       save_ifc,
       @save_ifc,
       IFCMaterial,
       ifc_material

####################################################
# IFC Material

struct IFCMaterial
  name::String
  red::Float64
  green::Float64
  blue::Float64
  alpha::Float64
  specularity::Float64
  roughness::Float64
end

ifc_material(name; gray=0.5,
             red=gray, green=gray, blue=gray,
             alpha=1.0, specularity=0.0, roughness=0.5) =
  IFCMaterial(name, Float64(red), Float64(green), Float64(blue),
              Float64(alpha), Float64(specularity), Float64(roughness))

const ifc_neutral = ifc_material("Default", gray=0.5)
const ifc_metal = ifc_material("Metal", gray=0.7, specularity=0.8, roughness=0.2)
const ifc_glass = ifc_material("Glass", gray=0.9, alpha=0.3, specularity=0.9, roughness=0.05)
const ifc_grass = ifc_material("Grass", red=0.2, green=0.5, blue=0.1)
const ifc_wood = ifc_material("Wood", red=0.5, green=0.3, blue=0.2)

####################################################
# IFC State — holds the Python model and spatial hierarchy

mutable struct IFCState
  ifc_mod::Py          # Python ifcopenshell module
  ifc_api::Py          # Python ifcopenshell.api module
  model::Py            # The IFC file model (or pybuiltins.None when uninitialized)
  context::Py          # IfcGeometricRepresentationContext
  body_context::Py     # Body sub-context
  project::Py
  site::Py
  building::Py
  storey_cache::Dict{Float64, Py}  # elevation → IfcBuildingStorey
  material_cache::Dict{String, Py}  # name → IfcSurfaceStyle
  entity_counter::Int
  initialized::Bool
end

IFCState() = IFCState(
  pynew(), pynew(), pynew(), pynew(), pynew(),
  pynew(), pynew(), pynew(),
  Dict{Float64, Py}(), Dict{String, Py}(), 0, false)

####################################################
# Backend type definition

@defbackend IFC IFC begin
  id_type = Int
  void_ref = -1
  parent = LocalBackend
  mixin(local_shapes)
  view::View = default_view()
  ifc_state::IFCState = IFCState()
end
const IFC_backend = IFC  # backward compatibility alias
const ifc = IFC()
KhepriBase.has_boolean_ops(::Type{IFC}) = HasBooleanOps{false}()

next_id!(b::IFC_backend) =
  let st = b.ifc_state
    st.entity_counter += 1
    st.entity_counter
  end

####################################################
# Lazy IFC model initialization

ensure_init!(b::IFC_backend) =
  let st = b.ifc_state
    if !st.initialized
      init_ifc_model!(st)
    end
    st
  end

function init_ifc_model!(st::IFCState)
  api = st.ifc_api
  model = st.ifc_mod.file(schema="IFC4")
  st.model = model

  # Create project and assign units
  st.project = api.run("root.create_entity", model,
    ifc_class="IfcProject", name="Khepri Project")
  let length_unit = api.run("unit.add_si_unit", model, unit_type="LENGTHUNIT"),
      area_unit = api.run("unit.add_si_unit", model, unit_type="AREAUNIT"),
      volume_unit = api.run("unit.add_si_unit", model, unit_type="VOLUMEUNIT"),
      angle_unit = api.run("unit.add_si_unit", model, unit_type="PLANEANGLEUNIT")
    api.run("unit.assign_unit", model,
      units=pylist([length_unit, area_unit, volume_unit, angle_unit]))
  end

  # Create geometry contexts
  st.context = api.run("context.add_context", model,
    context_type="Model")
  st.body_context = api.run("context.add_context", model,
    context_type="Model",
    context_identifier="Body",
    target_view="MODEL_VIEW",
    parent=st.context)

  # Create spatial hierarchy
  st.site = api.run("root.create_entity", model,
    ifc_class="IfcSite", name="Default Site")
  st.building = api.run("root.create_entity", model,
    ifc_class="IfcBuilding", name="Default Building")

  # Aggregate: Project → Site → Building
  api.run("aggregate.assign_object", model,
    relating_object=st.project, products=pylist([st.site]))
  api.run("aggregate.assign_object", model,
    relating_object=st.site, products=pylist([st.building]))

  st.initialized = true
  nothing
end

####################################################
# Storey management — lazily create storeys by elevation

get_or_create_storey!(st, elevation) =
  let key = round(Float64(elevation), digits=2)
    get!(st.storey_cache, key) do
      let storey = st.ifc_api.run("root.create_entity", st.model,
            ifc_class="IfcBuildingStorey",
            name = key == 0.0 ? "Ground Floor" : "Level @ $(key)m")
        storey.Elevation = Float64(key)
        st.ifc_api.run("aggregate.assign_object", st.model,
          relating_object=st.building, products=pylist([storey]))
        storey
      end
    end
  end

default_storey(st) = get_or_create_storey!(st, 0.0)

####################################################
# Geometry helpers — wrapping IfcOpenShell entity creation

ifc_point(model, loc) =
  let p = in_world(loc)
    model.createIfcCartesianPoint(pylist([Float64(p.x), Float64(p.y), Float64(p.z)]))
  end

ifc_point2d(model, x, y) =
  model.createIfcCartesianPoint(pylist([Float64(x), Float64(y)]))

ifc_direction(model, v) =
  model.createIfcDirection(pylist([Float64(v.x), Float64(v.y), Float64(v.z)]))

ifc_direction_raw(model, x, y, z) =
  model.createIfcDirection(pylist([Float64(x), Float64(y), Float64(z)]))

ifc_axis2placement3d(model, origin, z_dir, x_dir) =
  model.createIfcAxis2Placement3D(
    ifc_point(model, origin),
    ifc_direction_raw(model, z_dir...),
    ifc_direction_raw(model, x_dir...))

ifc_axis2placement3d(model; origin=u0(), z_axis=(0,0,1), x_axis=(1,0,0)) =
  ifc_axis2placement3d(model, origin, z_axis, x_axis)

ifc_axis2placement2d(model, origin_2d, x_dir_2d) =
  model.createIfcAxis2Placement2D(
    ifc_point2d(model, origin_2d...),
    model.createIfcDirection(pylist([Float64(x_dir_2d[1]), Float64(x_dir_2d[2])])))

ifc_local_placement(model, origin; relative_to=nothing) =
  let axis = ifc_axis2placement3d(model, origin, (0,0,1), (1,0,0))
    isnothing(relative_to) ?
      model.createIfcLocalPlacement(pybuiltins.None, axis) :
      model.createIfcLocalPlacement(relative_to, axis)
  end

ifc_polyline(model, pts) =
  model.createIfcPolyLine(pylist([ifc_point(model, p) for p in pts]))

ifc_closed_profile(model, pts) =
  let poly = ifc_polyline(model, [pts..., pts[1]])
    model.createIfcArbitraryClosedProfileDef("AREA", pybuiltins.None, poly)
  end

ifc_rect_profile(model, width, depth) =
  model.createIfcRectangleProfileDef(
    "AREA", pybuiltins.None,
    ifc_axis2placement2d(model, (0.0, 0.0), (1.0, 0.0)),
    Float64(width), Float64(depth))

ifc_circle_profile(model, radius) =
  model.createIfcCircleProfileDef(
    "AREA", pybuiltins.None,
    ifc_axis2placement2d(model, (0.0, 0.0), (1.0, 0.0)),
    Float64(radius))

ifc_extruded_solid(model, profile, direction, depth; position=nothing) =
  let dir = ifc_direction_raw(model, direction...),
      pos = isnothing(position) ?
        ifc_axis2placement3d(model) :
        position
    model.createIfcExtrudedAreaSolid(profile, pos, dir, Float64(depth))
  end

ifc_faceted_brep(model, face_point_lists) =
  let faces = pylist([
        model.createIfcFace(pylist([
          model.createIfcFaceOuterBound(
            model.createIfcPolyLoop(pylist([ifc_point(model, p) for p in pts])),
            pybuiltins.True)]))
        for pts in face_point_lists])
    model.createIfcFacetedBrep(
      model.createIfcClosedShell(faces))
  end

ifc_box_faces(p0, p1, p2, p3, p4, p5, p6, p7) =
  [[p0, p3, p2, p1],   # bottom
   [p4, p5, p6, p7],   # top
   [p0, p1, p5, p4],   # front
   [p2, p3, p7, p6],   # back
   [p0, p4, p7, p3],   # left
   [p1, p2, p6, p5]]   # right

ifc_shape_representation(st, rep_type, items) =
  st.model.createIfcShapeRepresentation(
    st.body_context, "Body", rep_type, pylist(items))

####################################################
# Property set helper

add_pset!(st, element, pset_name, properties) =
  let pset = st.ifc_api.run("pset.add_pset", st.model,
        product=element, name=pset_name)
    st.ifc_api.run("pset.edit_pset", st.model,
      pset=pset, properties=pydict(properties))
  end

####################################################
# Element creation helpers

ifc_create_element!(st, ifc_class, name, solid, placement_origin; storey=default_storey(st), predefined_type=nothing) =
  let api = st.ifc_api,
      model = st.model,
      element = api.run("root.create_entity", model, ifc_class=ifc_class, name=name),
      representation = ifc_shape_representation(st, "SweptSolid", [solid]),
      product_shape = model.createIfcProductDefinitionShape(
        pybuiltins.None, pybuiltins.None, pylist([representation])),
      placement = ifc_local_placement(model, placement_origin)
    element.Representation = product_shape
    element.ObjectPlacement = placement
    !isnothing(predefined_type) && (element.PredefinedType = predefined_type)
    api.run("spatial.assign_container", model,
      relating_structure=storey, products=pylist([element]))
    element
  end

ifc_create_brep_element!(st, ifc_class, name, brep, placement_origin; storey=default_storey(st), predefined_type=nothing) =
  let api = st.ifc_api,
      model = st.model,
      element = api.run("root.create_entity", model, ifc_class=ifc_class, name=name),
      representation = ifc_shape_representation(st, "Brep", [brep]),
      product_shape = model.createIfcProductDefinitionShape(
        pybuiltins.None, pybuiltins.None, pylist([representation])),
      placement = ifc_local_placement(model, placement_origin)
    element.Representation = product_shape
    element.ObjectPlacement = placement
    !isnothing(predefined_type) && (element.PredefinedType = predefined_type)
    api.run("spatial.assign_container", model,
      relating_structure=storey, products=pylist([element]))
    element
  end

####################################################
# Material operations

ensure_ifc_material!(st, mat::IFCMaterial) =
  get!(st.material_cache, mat.name) do
    let model = st.model,
        api = st.ifc_api,
        ifc_mat = api.run("material.add_material", model, name=mat.name),
        colour = model.createIfcColourRgb(
          pybuiltins.None, mat.red, mat.green, mat.blue),
        rendering = model.createIfcSurfaceStyleRendering(
          colour, mat.alpha,
          pybuiltins.None, pybuiltins.None, pybuiltins.None,
          pybuiltins.None, pybuiltins.None, pybuiltins.None,
          "FLAT"),
        style = model.createIfcSurfaceStyle(
          mat.name, "BOTH", pylist([rendering]))
      api.run("style.assign_material_style", model,
        material=ifc_mat, style=style, context=st.body_context)
      ifc_mat
    end
  end

assign_material!(st, element, mat::IFCMaterial) =
  let ifc_mat = ensure_ifc_material!(st, mat)
    st.ifc_api.run("material.assign_material", st.model,
      products=pylist([element]), material=ifc_mat)
  end

KhepriBase.b_material(b::IFC_backend, name,
                          base_color,
                          metallic, roughness, specular,
                          ior,
                          transmission, transmission_roughness,
                          clearcoat, clearcoat_roughness,
                          emission_color,
                          emission_strength) =
  ifc_material(name,
    red=Float64(red(base_color)),
    green=Float64(green(base_color)),
    blue=Float64(blue(base_color)),
    alpha=Float64(alpha(base_color)),
    specularity=Float64(specular),
    roughness=Float64(roughness))

KhepriBase.b_plastic_material(b::IFC_backend, name, color, roughness) =
  ifc_material(name,
    red=Float64(red(color)),
    green=Float64(green(color)),
    blue=Float64(blue(color)),
    roughness=Float64(roughness))

KhepriBase.b_metal_material(b::IFC_backend, name, color, roughness, ior) =
  ifc_material(name,
    red=Float64(red(color)),
    green=Float64(green(color)),
    blue=Float64(blue(color)),
    specularity=0.8,
    roughness=Float64(roughness))

KhepriBase.b_glass_material(b::IFC_backend, name, color, roughness, ior) =
  ifc_material(name,
    red=Float64(red(color)),
    green=Float64(green(color)),
    blue=Float64(blue(color)),
    alpha=0.3,
    specularity=0.9,
    roughness=Float64(roughness))

KhepriBase.b_mirror_material(b::IFC_backend, name, color) =
  ifc_material(name,
    red=Float64(red(color)),
    green=Float64(green(color)),
    blue=Float64(blue(color)),
    specularity=1.0,
    roughness=0.0)

####################################################
# Core b_* operations — geometry primitives

KhepriBase.b_trig(b::IFC_backend, p1, p2, p3, mat) =
  let st = ensure_init!(b),
      brep = ifc_faceted_brep(st.model, [[in_world(p1), in_world(p2), in_world(p3)]]),
      element = ifc_create_brep_element!(st, "IfcBuildingElementProxy", "Triangle", brep, u0())
    mat isa IFCMaterial && assign_material!(st, element, mat)
    next_id!(b)
  end

KhepriBase.b_surface_polygon(b::IFC_backend, ps, mat) =
  let st = ensure_init!(b),
      wps = in_world.(ps),
      brep = ifc_faceted_brep(st.model, [wps]),
      element = ifc_create_brep_element!(st, "IfcBuildingElementProxy", "Polygon", brep, u0())
    mat isa IFCMaterial && assign_material!(st, element, mat)
    next_id!(b)
  end

KhepriBase.b_surface_polygon_with_holes(b::IFC_backend, ps, qss, mat) =
  # IFC doesn't easily support polygon-with-holes as a single face;
  # emit outer face plus reversed hole faces as separate faces in the Brep
  let st = ensure_init!(b),
      faces = [in_world.(ps), [reverse(in_world.(qs)) for qs in qss]...],
      brep = ifc_faceted_brep(st.model, faces),
      element = ifc_create_brep_element!(st, "IfcBuildingElementProxy", "PolygonWithHoles", brep, u0())
    mat isa IFCMaterial && assign_material!(st, element, mat)
    next_id!(b)
  end

####################################################
# Solid primitives

KhepriBase.b_box(b::IFC_backend, c, dx, dy, dz, mat) =
  let st = ensure_init!(b),
      model = st.model,
      profile = ifc_rect_profile(model, dx, dy),
      position = ifc_axis2placement3d(model, c, (0,0,1), (1,0,0)),
      solid = ifc_extruded_solid(model, profile, (0,0,1), dz, position=position),
      element = ifc_create_element!(st, "IfcBuildingElementProxy", "Box", solid, c)
    mat isa IFCMaterial && assign_material!(st, element, mat)
    next_id!(b)
  end

KhepriBase.b_cylinder(b::IFC_backend, cb, r, h, bmat, tmat, smat) =
  let st = ensure_init!(b),
      model = st.model,
      profile = ifc_circle_profile(model, r),
      position = ifc_axis2placement3d(model, cb, (0,0,1), (1,0,0)),
      solid = ifc_extruded_solid(model, profile, (0,0,1), h, position=position),
      element = ifc_create_element!(st, "IfcBuildingElementProxy", "Cylinder", solid, cb)
    smat isa IFCMaterial && assign_material!(st, element, smat)
    next_id!(b)
  end

####################################################
# Critical extrusion — b_extruded_surface
#
# This is the linchpin: KhepriBase's default b_slab, b_wall, b_beam all cascade here.
# We override it to produce proper IfcExtrudedAreaSolid geometry.

KhepriBase.b_extruded_surface(b::IFC_backend, profile, v, cb, bmat, tmat, smat) =
  let st = ensure_init!(b),
      model = st.model,
      # Extract profile vertices in world coords relative to cb
      pts = path_vertices(outer_path(profile)),
      wpts = in_world.(pts),
      wcb = in_world(cb),
      # Transform to local coords relative to cb for the profile definition
      local_pts = [xyz(wp.x - wcb.x, wp.y - wcb.y, wp.z - wcb.z) for wp in wpts],
      # Create 2D profile from XY plane projection
      pts_2d = [ifc_point2d(model, Float64(p.x), Float64(p.y)) for p in local_pts],
      poly = model.createIfcPolyLine(pylist([pts_2d..., pts_2d[1]])),
      closed_profile = model.createIfcArbitraryClosedProfileDef("AREA", pybuiltins.None, poly),
      # Compute extrusion direction and depth
      wv = in_world(v),
      depth = norm(wv),
      dir = depth > 0 ? (wv.x/depth, wv.y/depth, wv.z/depth) : (0.0, 0.0, 1.0),
      position = ifc_axis2placement3d(model, cb, (0,0,1), (1,0,0)),
      solid = ifc_extruded_solid(model, closed_profile, dir, depth, position=position),
      element = ifc_create_element!(st, "IfcBuildingElementProxy", "Extrusion", solid, cb)
    smat isa IFCMaterial && assign_material!(st, element, smat)
    next_id!(b)
  end

####################################################
# Native BIM operations — override defaults with proper IFC entity types

# Wall — override realize to produce native IfcWall entities.
# The default KhepriBase realize for HasBooleanOps{false} doesn't call b_wall,
# so we must intercept at the realize level.
KhepriBase.realize(b::IFC_backend, w::Wall) =
  let w_base_height = w.bottom_level.height,
      w_height = w.top_level.height - w_base_height,
      w_path = translate(w.path, vz(w_base_height)),
      r_th = r_thickness(w),
      l_th = l_thickness(w),
      thickness = l_th + r_th
    path_length(w_path) < path_tolerance() ?
      void_ref(b) :
      let st = ensure_init!(b),
          api = st.ifc_api,
          model = st.model,
          storey = get_or_create_storey!(st, w_base_height),
          segments = subpaths(w_path),
          openings = [w.doors..., w.windows...],
          refs = new_refs(b),
          prevlength = 0.0
        for seg in segments
          let vs = path_vertices(seg),
              p0 = in_world(vs[1]),
              p1 = in_world(vs[end]),
              seg_length = path_length(seg),
              currlength = prevlength + seg_length,
              wall_element = api.run("root.create_entity", model, ifc_class="IfcWall"),
              representation = api.run("geometry.add_wall_representation", model,
                context=st.body_context,
                length=Float64(seg_length),
                height=Float64(w_height),
                thickness=Float64(thickness)),
              # Compute wall placement: position at p0, direction along wall axis
              dx = p1.x - p0.x,
              dy = p1.y - p0.y,
              seg_len_2d = sqrt(dx^2 + dy^2),
              x_dir = seg_len_2d > 0 ? (dx/seg_len_2d, dy/seg_len_2d, 0.0) : (1.0, 0.0, 0.0),
              # Offset by r_thickness in the perpendicular direction
              origin = xyz(p0.x - x_dir[2] * r_th,
                           p0.y + x_dir[1] * r_th,
                           p0.z),
              placement = ifc_local_placement(model, origin),
              axis = ifc_axis2placement3d(model, origin, (0,0,1), x_dir)
            api.run("geometry.assign_representation", model,
              product=wall_element, representation=representation)
            wall_element.ObjectPlacement = placement
            api.run("spatial.assign_container", model,
              relating_structure=storey, products=pylist([wall_element]))
            let mat = material_ref(b, w.family.right_material)
              mat isa IFCMaterial && assign_material!(st, wall_element, mat)
            end
            add_pset!(st, wall_element, "Pset_WallCommon",
              Dict("IsExternal" => false, "LoadBearing" => true))
            # Process doors and windows for this segment
            for op in openings
              let op_start = op.loc.x,
                  op_end = op_start + op.family.width
                if op_start >= prevlength && op_end <= currlength
                  let op_offset = op_start - prevlength,
                      op_width = op.family.width,
                      op_height = op.family.height,
                      op_z = op.loc.y,
                      op_thickness = thickness + 0.02,
                      # Opening position relative to wall element placement
                      # x along wall direction, y perpendicular (centered), z vertical
                      op_origin = xyz(op_offset, -0.01, op_z)
                    let opening = ifc_create_opening!(st, wall_element, storey,
                          op_origin, (1.0, 0.0, 0.0), op_width, op_height, op_thickness)
                      if op isa Door
                        ifc_create_door!(st, opening, storey,
                          op_origin, (1.0, 0.0, 0.0), op_width, op_height)
                      else
                        ifc_create_window!(st, opening, storey,
                          op_origin, (1.0, 0.0, 0.0), op_width, op_height)
                      end
                    end
                  end
                end
              end
            end
            prevlength = currlength
            push!(refs, next_id!(b))
          end
        end
        refs
      end
  end

# Slab — native IfcSlab with extruded profile
KhepriBase.b_slab(b::IFC_backend, profile, level, family) =
  let st = ensure_init!(b),
      model = st.model,
      api = st.ifc_api,
      thickness = slab_family_thickness(b, family),
      elevation = level_height(b, level) + slab_family_elevation(b, family),
      pts = path_vertices(outer_path(profile)),
      wpts = in_world.(pts),
      # Build 2D profile at elevation
      pts_2d = [ifc_point2d(model, Float64(p.x), Float64(p.y)) for p in wpts],
      poly = model.createIfcPolyLine(pylist([pts_2d..., pts_2d[1]])),
      closed_profile = model.createIfcArbitraryClosedProfileDef("AREA", pybuiltins.None, poly),
      origin = xyz(0, 0, elevation),
      position = ifc_axis2placement3d(model, origin, (0,0,1), (1,0,0)),
      solid = ifc_extruded_solid(model, closed_profile, (0,0,1), thickness, position=position),
      slab = api.run("root.create_entity", model, ifc_class="IfcSlab", name="Slab"),
      representation = ifc_shape_representation(st, "SweptSolid", [solid]),
      product_shape = model.createIfcProductDefinitionShape(
        pybuiltins.None, pybuiltins.None, pylist([representation])),
      placement = ifc_local_placement(model, origin)
    slab.Representation = product_shape
    slab.ObjectPlacement = placement
    api.run("spatial.assign_container", model,
      relating_structure=get_or_create_storey!(st, level_height(b, level)),
      products=pylist([slab]))
    if hasproperty(family, :top_material)
      let mat = material_ref(b, family.top_material)
        mat isa IFCMaterial && assign_material!(st, slab, mat)
      end
    end
    add_pset!(st, slab, "Pset_SlabCommon",
      Dict("IsExternal" => false, "LoadBearing" => true))
    next_id!(b)
  end

# Roof delegates to slab with IfcRoof entity
KhepriBase.b_roof(b::IFC_backend, profile, level, family) =
  let st = ensure_init!(b),
      model = st.model,
      api = st.ifc_api,
      thickness = slab_family_thickness(b, family),
      elevation = level_height(b, level) + slab_family_elevation(b, family),
      pts = path_vertices(outer_path(profile)),
      wpts = in_world.(pts),
      pts_2d = [ifc_point2d(model, Float64(p.x), Float64(p.y)) for p in wpts],
      poly = model.createIfcPolyLine(pylist([pts_2d..., pts_2d[1]])),
      closed_profile = model.createIfcArbitraryClosedProfileDef("AREA", pybuiltins.None, poly),
      origin = xyz(0, 0, elevation),
      position = ifc_axis2placement3d(model, origin, (0,0,1), (1,0,0)),
      solid = ifc_extruded_solid(model, closed_profile, (0,0,1), thickness, position=position),
      roof = api.run("root.create_entity", model, ifc_class="IfcRoof", name="Roof"),
      representation = ifc_shape_representation(st, "SweptSolid", [solid]),
      product_shape = model.createIfcProductDefinitionShape(
        pybuiltins.None, pybuiltins.None, pylist([representation])),
      placement = ifc_local_placement(model, origin)
    roof.Representation = product_shape
    roof.ObjectPlacement = placement
    api.run("spatial.assign_container", model,
      relating_structure=get_or_create_storey!(st, level_height(b, level)),
      products=pylist([roof]))
    add_pset!(st, roof, "Pset_SlabCommon",
      Dict("IsExternal" => true))
    next_id!(b)
  end

# Beam — native IfcBeam
KhepriBase.b_beam(b::IFC_backend, c, h, angle, family) =
  let st = ensure_init!(b),
      model = st.model,
      api = st.ifc_api,
      c = loc_from_o_phi(c, angle),
      prof = family_profile(b, family),
      pts = path_vertices(prof),
      # Build 2D profile
      pts_2d = [ifc_point2d(model, Float64(p.x), Float64(p.y)) for p in pts],
      poly = model.createIfcPolyLine(pylist([pts_2d..., pts_2d[1]])),
      closed_profile = model.createIfcArbitraryClosedProfileDef("AREA", pybuiltins.None, poly),
      position = ifc_axis2placement3d(model, c, (0,0,1), (1,0,0)),
      solid = ifc_extruded_solid(model, closed_profile, (0,0,1), h, position=position),
      beam = api.run("root.create_entity", model, ifc_class="IfcBeam", name="Beam"),
      representation = ifc_shape_representation(st, "SweptSolid", [solid]),
      product_shape = model.createIfcProductDefinitionShape(
        pybuiltins.None, pybuiltins.None, pylist([representation])),
      placement = ifc_local_placement(model, c)
    beam.Representation = product_shape
    beam.ObjectPlacement = placement
    api.run("spatial.assign_container", model,
      relating_structure=default_storey(st), products=pylist([beam]))
    if hasproperty(family, :material)
      let mat = material_ref(b, family.material)
        mat isa IFCMaterial && assign_material!(st, beam, mat)
      end
    end
    add_pset!(st, beam, "Pset_BeamCommon",
      Dict("IsExternal" => false, "LoadBearing" => true))
    next_id!(b)
  end

# Column — native IfcColumn (delegates to beam positioning)
KhepriBase.b_column(b::IFC_backend, cb, angle, bottom_level, top_level, family) =
  let st = ensure_init!(b),
      model = st.model,
      api = st.ifc_api,
      base_height = level_height(b, bottom_level),
      top_height = level_height(b, top_level),
      h = top_height - base_height,
      c = add_z(loc_from_o_phi(cb, angle), base_height),
      prof = family_profile(b, family),
      pts = path_vertices(prof),
      pts_2d = [ifc_point2d(model, Float64(p.x), Float64(p.y)) for p in pts],
      poly = model.createIfcPolyLine(pylist([pts_2d..., pts_2d[1]])),
      closed_profile = model.createIfcArbitraryClosedProfileDef("AREA", pybuiltins.None, poly),
      position = ifc_axis2placement3d(model, c, (0,0,1), (1,0,0)),
      solid = ifc_extruded_solid(model, closed_profile, (0,0,1), h, position=position),
      column = api.run("root.create_entity", model, ifc_class="IfcColumn", name="Column"),
      representation = ifc_shape_representation(st, "SweptSolid", [solid]),
      product_shape = model.createIfcProductDefinitionShape(
        pybuiltins.None, pybuiltins.None, pylist([representation])),
      placement = ifc_local_placement(model, c)
    column.Representation = product_shape
    column.ObjectPlacement = placement
    api.run("spatial.assign_container", model,
      relating_structure=get_or_create_storey!(st, level_height(b, bottom_level)),
      products=pylist([column]))
    if hasproperty(family, :material)
      let mat = material_ref(b, family.material)
        mat isa IFCMaterial && assign_material!(st, column, mat)
      end
    end
    add_pset!(st, column, "Pset_ColumnCommon",
      Dict("IsExternal" => false, "LoadBearing" => true))
    next_id!(b)
  end

####################################################
# Door/Window support — IfcOpeningElement + IfcDoor/IfcWindow

# Create an opening void in a wall element
ifc_create_opening!(st, wall_element, storey, origin, x_dir, width, height, thickness) =
  let api = st.ifc_api,
      model = st.model,
      opening = api.run("root.create_entity", model, ifc_class="IfcOpeningElement", name="Opening"),
      profile = ifc_rect_profile(model, width, height),
      solid = ifc_extruded_solid(model, profile, (0,0,1), thickness),
      representation = ifc_shape_representation(st, "SweptSolid", [solid]),
      product_shape = model.createIfcProductDefinitionShape(
        pybuiltins.None, pybuiltins.None, pylist([representation])),
      placement = model.createIfcLocalPlacement(
        wall_element.ObjectPlacement,
        ifc_axis2placement3d(model, origin, (0,0,1), x_dir))
    opening.Representation = product_shape
    opening.ObjectPlacement = placement
    api.run("spatial.assign_container", model,
      relating_structure=storey, products=pylist([opening]))
    api.run("feature.add_feature", model,
      element=wall_element, feature=opening)
    opening
  end

# Create a door filling an opening
ifc_create_door!(st, opening, storey, origin, x_dir, width, height) =
  let api = st.ifc_api,
      model = st.model,
      door = api.run("root.create_entity", model, ifc_class="IfcDoor", name="Door")
    door.OverallWidth = Float64(width)
    door.OverallHeight = Float64(height)
    let profile = ifc_rect_profile(model, width, height),
        solid = ifc_extruded_solid(model, profile, (0,0,1), 0.05),
        representation = ifc_shape_representation(st, "SweptSolid", [solid]),
        product_shape = model.createIfcProductDefinitionShape(
          pybuiltins.None, pybuiltins.None, pylist([representation])),
        placement = model.createIfcLocalPlacement(
          opening.ObjectPlacement,
          ifc_axis2placement3d(model))
      door.Representation = product_shape
      door.ObjectPlacement = placement
    end
    api.run("spatial.assign_container", model,
      relating_structure=storey, products=pylist([door]))
    api.run("feature.add_filling", model,
      opening=opening, element=door)
    add_pset!(st, door, "Pset_DoorCommon",
      Dict("IsExternal" => false))
    door
  end

# Create a window filling an opening
ifc_create_window!(st, opening, storey, origin, x_dir, width, height) =
  let api = st.ifc_api,
      model = st.model,
      win = api.run("root.create_entity", model, ifc_class="IfcWindow", name="Window")
    win.OverallWidth = Float64(width)
    win.OverallHeight = Float64(height)
    let profile = ifc_rect_profile(model, width, height),
        solid = ifc_extruded_solid(model, profile, (0,0,1), 0.05),
        representation = ifc_shape_representation(st, "SweptSolid", [solid]),
        product_shape = model.createIfcProductDefinitionShape(
          pybuiltins.None, pybuiltins.None, pylist([representation])),
        placement = model.createIfcLocalPlacement(
          opening.ObjectPlacement,
          ifc_axis2placement3d(model))
      win.Representation = product_shape
      win.ObjectPlacement = placement
    end
    api.run("spatial.assign_container", model,
      relating_structure=storey, products=pylist([win]))
    api.run("feature.add_filling", model,
      opening=opening, element=win)
    add_pset!(st, win, "Pset_WindowCommon",
      Dict("IsExternal" => false))
    win
  end

# Override realize for Door/Window to prevent default KhepriBase geometry
KhepriBase.realize(b::IFC_backend, s::Union{Door, Window}) = next_id!(b)

####################################################
# BIM Ceiling, Stair, Ramp, Railing operations

# Ceiling — IfcCovering with PredefinedType=CEILING
KhepriBase.b_ceiling(b::IFC_backend, profile, level, family) =
  let st = ensure_init!(b),
      model = st.model,
      thickness = ceiling_family_thickness(b, family),
      elevation = level_height(b, level) - thickness + ceiling_family_elevation(b, family),
      pts = path_vertices(outer_path(profile)),
      wpts = in_world.(pts),
      pts_2d = [ifc_point2d(model, Float64(p.x), Float64(p.y)) for p in wpts],
      poly = model.createIfcPolyLine(pylist([pts_2d..., pts_2d[1]])),
      closed_profile = model.createIfcArbitraryClosedProfileDef("AREA", pybuiltins.None, poly),
      origin = xyz(0, 0, elevation),
      position = ifc_axis2placement3d(model, origin, (0,0,1), (1,0,0)),
      solid = ifc_extruded_solid(model, closed_profile, (0,0,1), thickness, position=position),
      covering = ifc_create_element!(st, "IfcCovering", "Ceiling", solid, origin,
        storey=get_or_create_storey!(st, level_height(b, level)),
        predefined_type="CEILING")
    if hasproperty(family, :bottom_material)
      let mat = material_ref(b, family.bottom_material)
        mat isa IFCMaterial && assign_material!(st, covering, mat)
      end
    end
    add_pset!(st, covering, "Pset_CoveringCommon",
      Dict("IsExternal" => false))
    next_id!(b)
  end

# Stair Landing — IfcSlab with PredefinedType=LANDING
KhepriBase.b_stair_landing(b::IFC_backend, region, level, family) =
  let st = ensure_init!(b),
      model = st.model,
      thickness = slab_family_thickness(b, family),
      elevation = level_height(b, level) + slab_family_elevation(b, family),
      pts = path_vertices(outer_path(region)),
      wpts = in_world.(pts),
      pts_2d = [ifc_point2d(model, Float64(p.x), Float64(p.y)) for p in wpts],
      poly = model.createIfcPolyLine(pylist([pts_2d..., pts_2d[1]])),
      closed_profile = model.createIfcArbitraryClosedProfileDef("AREA", pybuiltins.None, poly),
      origin = xyz(0, 0, elevation),
      position = ifc_axis2placement3d(model, origin, (0,0,1), (1,0,0)),
      solid = ifc_extruded_solid(model, closed_profile, (0,0,1), thickness, position=position),
      landing = ifc_create_element!(st, "IfcSlab", "Landing", solid, origin,
        storey=get_or_create_storey!(st, level_height(b, level)),
        predefined_type="LANDING")
    if hasproperty(family, :top_material)
      let mat = material_ref(b, family.top_material)
        mat isa IFCMaterial && assign_material!(st, landing, mat)
      end
    end
    add_pset!(st, landing, "Pset_SlabCommon",
      Dict("IsExternal" => false))
    next_id!(b)
  end

# Stair — IfcStairFlight with FacetedBrep step geometry
KhepriBase.b_stair(b::IFC_backend, base_point, direction, bottom_level, top_level, family) =
  let st = ensure_init!(b),
      model = st.model,
      bottom_h = level_height(b, bottom_level),
      top_h = level_height(b, top_level),
      total_h = top_h - bottom_h,
      n_steps = Int(round(total_h / family.riser_height)),
      riser_h = total_h / n_steps,
      tread_d = family.tread_depth,
      w = family.width,
      dir = unitized(direction),
      perp = cross(vz(1), dir),
      bp = in_world(base_point),
      faces = []
    for i in 0:(n_steps - 1)
      let base = bp + dir * (i * tread_d) + vz(bottom_h + i * riser_h),
          tread = [base + vz(riser_h),
                   base + perp * w + vz(riser_h),
                   base + dir * tread_d + perp * w + vz(riser_h),
                   base + dir * tread_d + vz(riser_h)]
        push!(faces, tread)
        if family.has_risers
          let riser = [base, base + perp * w,
                       base + perp * w + vz(riser_h), base + vz(riser_h)]
            push!(faces, riser)
          end
        end
      end
    end
    let brep = ifc_faceted_brep(model, faces),
        flight = ifc_create_brep_element!(st, "IfcStairFlight", "Stair", brep, u0(),
          storey=get_or_create_storey!(st, bottom_h))
      if hasproperty(family, :tread_material)
        let mat = material_ref(b, family.tread_material)
          mat isa IFCMaterial && assign_material!(st, flight, mat)
        end
      end
      add_pset!(st, flight, "Pset_StairFlightCommon",
        Dict("NumberOfRisers" => n_steps,
             "NumberOfTreads" => n_steps,
             "RiserHeight" => Float64(riser_h),
             "TreadLength" => Float64(tread_d)))
      next_id!(b)
    end
  end

# Spiral Stair — IfcStairFlight with polar-coordinate tread geometry
KhepriBase.b_spiral_stair(b::IFC_backend, center, radius, start_angle, included_angle,
                           clockwise, bottom_level, top_level, family) =
  let st = ensure_init!(b),
      model = st.model,
      bottom_h = level_height(b, bottom_level),
      top_h = level_height(b, top_level),
      total_h = top_h - bottom_h,
      n_steps = Int(round(total_h / family.riser_height)),
      riser_h = total_h / n_steps,
      sign = clockwise ? -1 : 1,
      angle_step = sign * included_angle / n_steps,
      w = family.width,
      r_inner = radius - w/2,
      r_outer = radius + w/2,
      c = in_world(center),
      faces = []
    for i in 0:(n_steps - 1)
      let a0 = start_angle + i * angle_step,
          a1 = a0 + angle_step,
          h = bottom_h + (i + 1) * riser_h,
          tread = [c + vpol(r_inner, a0) + vz(h),
                   c + vpol(r_outer, a0) + vz(h),
                   c + vpol(r_outer, a1) + vz(h),
                   c + vpol(r_inner, a1) + vz(h)]
        push!(faces, tread)
      end
    end
    let brep = ifc_faceted_brep(model, faces),
        flight = ifc_create_brep_element!(st, "IfcStairFlight", "SpiralStair", brep, u0(),
          storey=get_or_create_storey!(st, bottom_h))
      if hasproperty(family, :tread_material)
        let mat = material_ref(b, family.tread_material)
          mat isa IFCMaterial && assign_material!(st, flight, mat)
        end
      end
      add_pset!(st, flight, "Pset_StairFlightCommon",
        Dict("NumberOfRisers" => n_steps,
             "NumberOfTreads" => n_steps,
             "RiserHeight" => Float64(riser_h)))
      next_id!(b)
    end
  end

# Ramp — IfcRampFlight with inclined solid geometry
KhepriBase.b_ramp(b::IFC_backend, path, bottom_level, top_level, family) =
  let st = ensure_init!(b),
      model = st.model,
      bottom_h = level_height(b, bottom_level),
      top_h = level_height(b, top_level),
      w = family.width,
      th = family.thickness,
      p0 = in_world(path_start(path)),
      p1 = in_world(path_end(path)),
      dir = unitized(p1 - p0),
      perp = cross(dir, vz(1)),
      b0 = p0 + perp * (w/2) + vz(bottom_h),
      b1 = p0 - perp * (w/2) + vz(bottom_h),
      b2 = p0 - perp * (w/2) + vz(bottom_h - th),
      b3 = p0 + perp * (w/2) + vz(bottom_h - th),
      t0 = p1 + perp * (w/2) + vz(top_h),
      t1 = p1 - perp * (w/2) + vz(top_h),
      t2 = p1 - perp * (w/2) + vz(top_h - th),
      t3 = p1 + perp * (w/2) + vz(top_h - th),
      faces = [
        [b0, t0, t1, b1],       # top surface
        [b3, b2, t2, t3],       # bottom surface
        [b0, b3, t3, t0],       # left side
        [b1, t1, t2, b2],       # right side
        [b0, b1, b2, b3],       # start face
        [t0, t3, t2, t1]],      # end face
      brep = ifc_faceted_brep(model, faces),
      ramp_flight = ifc_create_brep_element!(st, "IfcRampFlight", "Ramp", brep, u0(),
        storey=get_or_create_storey!(st, bottom_h))
    if hasproperty(family, :top_material)
      let mat = material_ref(b, family.top_material)
        mat isa IFCMaterial && assign_material!(st, ramp_flight, mat)
      end
    end
    let run = norm(p1 - p0),
        rise = top_h - bottom_h,
        slope = run > 0 ? rise / run : 0.0
      add_pset!(st, ramp_flight, "Pset_RampFlightCommon",
        Dict("Slope" => Float64(slope)))
    end
    next_id!(b)
  end

# Railing — IfcRailing with composite rail + post geometry
KhepriBase.b_railing(b::IFC_backend, path, level, host, family) =
  let st = ensure_init!(b),
      model = st.model,
      h = family.height,
      base = level_height(b, level),
      len = path_length(path),
      n_posts = max(2, Int(ceil(len / family.post_spacing)) + 1),
      post_w = 0.05,
      rail_w = 0.05,
      rail_h = 0.05,
      faces = []
    # Posts
    for t in division(0, len, n_posts - 1)
      let pt = in_world(location_at_length(path, t)),
          hw = post_w / 2
        append!(faces, ifc_box_faces(
          pt - vx(hw) - vy(hw) + vz(base),
          pt + vx(hw) - vy(hw) + vz(base),
          pt + vx(hw) + vy(hw) + vz(base),
          pt - vx(hw) + vy(hw) + vz(base),
          pt - vx(hw) - vy(hw) + vz(base + h),
          pt + vx(hw) - vy(hw) + vz(base + h),
          pt + vx(hw) + vy(hw) + vz(base + h),
          pt - vx(hw) + vy(hw) + vz(base + h)))
      end
    end
    # Rail segments
    let vs = path_vertices(path)
      for i in 1:(length(vs) - 1)
        let p0 = in_world(vs[i]),
            p1 = in_world(vs[i + 1]),
            d = unitized(p1 - p0),
            perp = cross(d, vz(1)),
            hw = rail_w / 2,
            z0 = base + h - rail_h,
            c0 = p0 + perp * hw + vz(z0),
            c1 = p1 + perp * hw + vz(z0),
            c2 = p1 - perp * hw + vz(z0),
            c3 = p0 - perp * hw + vz(z0)
          append!(faces, ifc_box_faces(
            c0, c1, c2, c3,
            c0 + vz(rail_h), c1 + vz(rail_h),
            c2 + vz(rail_h), c3 + vz(rail_h)))
        end
      end
    end
    let brep = ifc_faceted_brep(model, faces),
        railing_el = ifc_create_brep_element!(st, "IfcRailing", "Railing", brep, u0(),
          storey=get_or_create_storey!(st, base))
      if hasproperty(family, :material)
        let mat = material_ref(b, family.material)
          mat isa IFCMaterial && assign_material!(st, railing_el, mat)
        end
      end
      add_pset!(st, railing_el, "Pset_RailingCommon",
        Dict("Height" => Float64(h)))
      next_id!(b)
    end
  end

####################################################
# Delete all refs — reset the IFC model

KhepriBase.b_delete_all_shape_refs(b::IFC_backend) =
  let st = b.ifc_state
    empty!(b.shapes)
    for ss in values(b.layers)
      empty!(ss)
    end
    # Clear each refs dict individually (References has no empty! method)
    empty!(b.refs.shapes)
    empty!(b.refs.materials)
    empty!(b.refs.layers)
    empty!(b.refs.annotations)
    empty!(b.refs.families)
    empty!(b.refs.levels)
    # Reset IFC-specific state and re-initialize a fresh model
    empty!(st.storey_cache)
    empty!(st.material_cache)
    st.entity_counter = 0
    if st.initialized
      st.initialized = false
      init_ifc_model!(st)
    end
    nothing
  end

####################################################
# Save IFC file

save_ifc(path::String, b::IFC_backend=ifc) =
  let st = ensure_init!(b)
    realize_shapes(b)
    st.model.write(path)
    path
  end

macro save_ifc()
  :(save_ifc(splitext($(string(__source__.file)))[1]*".ifc"))
end
