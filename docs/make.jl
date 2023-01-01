using KhepriIFC
using Documenter

DocMeta.setdocmeta!(KhepriIFC, :DocTestSetup, :(using KhepriIFC); recursive=true)

makedocs(;
    modules=[KhepriIFC],
    authors="António Menezes Leitão <antonio.menezes.leitao@gmail.com>",
    repo="https://github.com/aptmcl/KhepriIFC.jl/blob/{commit}{path}#{line}",
    sitename="KhepriIFC.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://aptmcl.github.io/KhepriIFC.jl",
        edit_link="master",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/aptmcl/KhepriIFC.jl",
    devbranch="master",
)
