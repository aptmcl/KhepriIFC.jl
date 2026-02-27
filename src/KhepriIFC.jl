module KhepriIFC
using KhepriBase
using PythonCall

# Functions that need specialization from KhepriBase
include(khepribase_interface_file())
include("IFC.jl")

function __init__()
  # Initialize Python modules
  PythonCall.pycopy!(ifc.ifc_state.ifc_mod, pyimport("ifcopenshell"))
  PythonCall.pycopy!(ifc.ifc_state.ifc_api, pyimport("ifcopenshell.api"))

  # Map standard Khepri materials to IFC materials
  set_material(IFC_backend, material_basic, ifc_neutral)
  set_material(IFC_backend, material_metal, ifc_metal)
  set_material(IFC_backend, material_glass, ifc_glass)
  set_material(IFC_backend, material_grass, ifc_grass)
  set_material(IFC_backend, material_wood, ifc_wood)
  set_material(IFC_backend, material_clay, ifc_material("Clay", gray=0.5))
  set_material(IFC_backend, material_concrete, ifc_material("Concrete", gray=0.3))
  set_material(IFC_backend, material_plaster, ifc_material("Plaster", gray=0.7))

  add_current_backend(ifc)
end
end
