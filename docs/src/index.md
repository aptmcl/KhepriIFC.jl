```@meta
CurrentModule = KhepriIFC
```

# KhepriIFC

A Khepri backend for [IFC (Industry Foundation Classes)](https://www.buildingsmart.org/standards/bsi-standards/industry-foundation-classes/) file output via the Python `ifcopenshell` library.

## Architecture

KhepriIFC wraps the Python `ifcopenshell` library through PythonCall, providing Julia access to IFC file creation, reading, and manipulation.

- **Python bridge**: PythonCall to `ifcopenshell` and `ifcopenshell.api`
- **BIM hierarchy**: Site → Building → Storey → Elements
- **Property macros**: `@def_rw_property` and `@def_ro_property` for typed property access on IFC entities

## Key Features

- **IFC file creation**: Create BIM models from scratch with proper ownership and context
- **Building hierarchy**: `new_building()` and `new_storey()` for structured BIM output
- **Property access**: Typed read-write and read-only property macros with automatic name conversion (`:global_id` → `GlobalId`)
- **Entity manipulation**: Create, query, modify, and traverse IFC entities
- **Schema support**: Works with IFC2X3 and IFC4 schemas

## Usage

```julia
using KhepriIFC

# Access the ifcopenshell Python module
model = ifc.open("building.ifc")
walls = model.by_type("IfcWall")
```

## Dependencies

- **PythonCall**: Python interop
- **ifcopenshell**: Python IFC library (must be installed in the Python environment)

```@index
```

```@autodocs
Modules = [KhepriIFC]
```
