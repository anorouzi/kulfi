open Kulfi_Types

module type ShiftModel = sig
    val model : topology -> vertex -> demands -> demands
end

module NS = SM_Naive
module SD = SM_SD
