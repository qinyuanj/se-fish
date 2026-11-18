---AUTTO EXPORT BY EGGITOR PLUGIN, PLEASE DO NOT EDIT

return {
	-- 树状结构声明：
	-- 节点 = {name, type} 或 {name, type, {子节点...}}
	--   [1] name = 节点名
	--   [2] type = SE SDK 运行时类名
	--   [3] children = 子节点数组（叶子节点省略）
	{"ScreenMain", "EUILayout", {
		{"ImageCoin", "EUIImage"},
		{"LabelCoin", "EUITextLabel"},
	}},
	{"ScreenShop", "EUILayout", {
		{"ShopRootBG", "EUIImage", {
			{"ShopRoot", "EUIImage", {
				{"LabelCurCoin", "EUITextLabel"},
				{"BtnShopClose", "EUIButton", {
					{"LabelShopClose", "EUITextLabel"},
				}},
				{"LabelShopTitle", "EUITextLabel"},
				{"BtnShopPage1", "EUIButton", {
					{"LabelShopPage1", "EUITextLabel"},
				}},
				{"BtnShopPage2", "EUIButton", {
					{"LabelShopPage2", "EUITextLabel"},
				}},
				{"BtnShopPage3", "EUIButton", {
					{"LabelShopPage3", "EUITextLabel"},
				}},
				{"BtnShopPage4", "EUIButton", {
					{"LabelShopPage4", "EUITextLabel"},
				}},
				{"ShopListPanel", "EUIImage", {
					{"ShopList", "EUIListView"},
				}},
				{"ShopDetailPanel", "EUIImage", {
					{"ImageShopDetailIcon", "EUIImage"},
					{"LabelShopDetailName", "EUITextLabel"},
					{"LabelShopDetailDesc", "EUITextLabel"},
					{"ImageShopDetailCoin", "EUIImage"},
					{"LabelShopDetailPrice", "EUITextLabel"},
					{"LabelShopDetailLimit", "EUITextLabel"},
					{"LabelShopDetailUpgrade", "EUITextLabel"},
					{"BtnShopBuyDetail", "EUIButton", {
						{"LabelShopBuyDetail", "EUITextLabel"},
					}},
				}},
				{"ShopCoinPanel", "EUIImage", {
					{"LabelCoinPageHint", "EUITextLabel"},
					{"BtnOpenPlatformShop", "EUIButton", {
						{"LabelOpenPlatformShop", "EUITextLabel"},
					}},
				}},
				{"ImageShopCoin", "EUIImage"},
			}},
		}},
	}},
	{"DialogNoticeConfirm", "EUILayout", {
		{"BG", "EUIImage", {
			{"UIList", "EUIListView", {
				{"BtnYes", "EUIButton"},
				{"BtnNo", "EUIButton"},
			}},
			{"LabelText", "EUITextLabel"},
		}},
	}},
	{"ScreenMsg", "EUILayout", {
		{"ItemMsg", "EUIImage", {
			{"BG", "EUIImage"},
			{"LabelMsg", "EUITextLabel"},
		}},
	}},
	{"SceneNodeShop", "EUISceneNode", {
		{"LabelShopTitle", "EUITextLabel"},
	}},
	{"SceneNodeFish", "EUISceneNode", {
		{"LabelFishTitle", "EUITextLabel"},
	}},
}
