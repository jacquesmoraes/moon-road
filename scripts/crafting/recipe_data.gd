extends Resource
class_name RecipeData
## Data-driven craft recipe. Ingredients are parallel id/amount arrays.

@export var id: String = ""
@export var display_name: String = "Recipe"
@export var ingredient_item_ids: PackedStringArray = []
@export var ingredient_amounts: PackedInt32Array = []
@export var output_item_id: String = ""
@export var output_quantity: int = 1


func get_ingredients() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var n := mini(ingredient_item_ids.size(), ingredient_amounts.size())
	for i in range(n):
		var item_id := str(ingredient_item_ids[i])
		var amount := int(ingredient_amounts[i])
		if item_id.is_empty() or amount <= 0:
			continue
		out.append({"item_id": item_id, "amount": amount})
	return out
