"""Exercise the actual Food Trade Lua core and gameplay scripts with a fake engine."""
from __future__ import annotations

from pathlib import Path
import re
import sys
import unittest
import xml.etree.ElementTree as ET

try:
    from lupa.lua51 import LuaRuntime
except ImportError:
    raise SystemExit("Install lupa with Lua 5.1 support before running offline tests.")

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "FDT/Gameplay/FDT_Core.lua"
GAMEPLAY = ROOT / "FDT/Gameplay/FDT_Gameplay.lua"


class GameplayTests(unittest.TestCase):
    def setUp(self) -> None:
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute((Path(__file__).with_name("fake_engine.lua")).read_text(encoding="utf-8"))
        xml = ET.parse(ROOT / "FDT/Data/FDT_Buildings.xml").getroot()
        yields = {row.attrib["BuildingType"]: int(row.attrib["YieldChange"]) for row in xml.findall("./Building_YieldChanges/Row")}
        buildings = self.lua.table()
        rows = self.lua.table()
        for index, row in enumerate(xml.findall("./Buildings/Row"), 1):
            name = row.attrib["BuildingType"]
            record = self.lua.table_from({"Index": index, "BuildingType": name, "YieldChange": yields[name]})
            buildings[name] = record
            rows[index] = record
        self.lua.globals().GameInfo = self.lua.table_from({"Buildings": buildings})
        self.lua.globals().TEST.buildingRows = rows
        self.lua.execute(CORE.read_text(encoding="utf-8"))
        self.lua.execute(GAMEPLAY.read_text(encoding="utf-8"))

    def run_lua(self, source: str) -> None:
        self.lua.execute(source)

    def activate(self) -> None:
        self.run_lua("assert(FDT.Create(0,{senderCity=1,receiverCity=2,amount=5})); assert(TEST.advance())")

    def test_core_surplus_and_rounding(self) -> None:
        self.run_lua("""
          TEST.eq(FDT_Core.availableSurplus(2,5,3),4)
          for flow,expected in ipairs({2,2,2,2,3,3,3,3,4,4}) do TEST.eq(FDT_Core.cost(flow),expected) end
          TEST.eq(FDT_Core.cost(0),1)
        """)

    def test_core_oldest_first_and_no_input_mutation(self) -> None:
        self.run_lua("""
          local routes={
            {id=3,createdTurn=2,startTurn=0,senderPlayer=0,senderCity=1,amount=3,flow=99},
            {id=2,createdTurn=1,startTurn=0,senderPlayer=0,senderCity=1,amount=4,flow=99},
            {id=1,createdTurn=1,startTurn=0,senderPlayer=0,senderCity=1,amount=5,flow=99}}
          local result=FDT_Core.allocate(routes,{{owner=0,cityID=1,available=8}},10)
          TEST.eq(result[1].id,1); TEST.eq(result[1].flow,5); TEST.eq(result[2].flow,3); TEST.eq(result[3].flow,0)
          TEST.eq(routes[1].flow,99)
          result=FDT_Core.allocate(result,{{owner=0,cityID=1,available=12}},11)
          TEST.eq(result[1].flow,5); TEST.eq(result[2].flow,4); TEST.eq(result[3].flow,3)
        """)

    def test_creation_is_pending_no_initial_charge(self) -> None:
        self.run_lua("""
          assert(FDT.Create(0,{senderCity=1,receiverCity=2,amount=5}))
          TEST.eq(TEST.food(TEST.sender),8); TEST.eq(TEST.food(TEST.receiver),1)
          TEST.eq(FDT.GetState().routes[1].flow,0); TEST.eq(Players[0].gold,100)
          assert(FDT.ProcessTurn(10)); TEST.eq(Players[0].gold,100)
          TEST.eq(FDT.GetState().routes[1].zeroTurns,0)
          assert(TEST.advance()); TEST.eq(TEST.food(TEST.sender),3); TEST.eq(TEST.food(TEST.receiver),6)
          TEST.eq(Players[0].gold,97)
        """)

    def test_synced_handlers_are_registered(self) -> None:
        self.run_lua("""
          assert(GameEvents.FDT_Create.handler==FDT.Create)
          assert(GameEvents.FDT_Edit.handler==FDT.Edit)
          assert(GameEvents.FDT_Cancel.handler==FDT.Cancel)
          assert(GameEvents.OnGameTurnStarted.handler==FDT.ProcessTurn)
        """)

    def test_surplus_reconstructs_and_received_food_cannot_forward(self) -> None:
        self.activate()
        self.run_lua("""
          TEST.eq(FDT.GetAvailableSurplus(TEST.sender),8); TEST.eq(FDT.GetAvailableSurplus(TEST.receiver),1)
          assert(not FDT.Create(0,{senderCity=2,receiverCity=3,amount=2}))
          assert(FDT.Create(0,{senderCity=2,receiverCity=3,amount=1}))
          assert(TEST.advance())
          TEST.eq(FDT.GetState().routes[2].flow,1)
          TEST.eq(TEST.food(TEST.receiver),5); TEST.eq(TEST.food(TEST.third),3)
        """)

    def test_multiple_routes_can_oversubscribe_set_amounts(self) -> None:
        self.run_lua("""
          assert(FDT.Create(0,{senderCity=1,receiverCity=2,amount=8}))
          assert(FDT.Create(0,{senderCity=1,receiverCity=3,amount=8}))
          assert(TEST.advance())
          TEST.eq(FDT.GetState().routes[1].flow,8); TEST.eq(FDT.GetState().routes[2].flow,0)
          TEST.eq(Players[0].gold,96)
        """)

    def test_shrink_and_recover_notify_once_per_transition(self) -> None:
        self.activate()
        self.run_lua("""
          TEST.sender.base=2; assert(TEST.advance()); TEST.eq(FDT.GetState().routes[1].flow,2)
          TEST.eq(TEST.countNotices("route reduced"),1)
          assert(TEST.advance()); TEST.eq(TEST.countNotices("route reduced"),1)
          TEST.sender.base=8; assert(TEST.advance()); TEST.eq(FDT.GetState().routes[1].flow,5)
          TEST.eq(TEST.countNotices("route restored"),1)
        """)

    def test_zero_flow_still_costs_one_gold(self) -> None:
        self.activate()
        self.run_lua("""
          TEST.sender.base=0; local before=Players[0].gold; assert(TEST.advance())
          TEST.eq(Players[0].gold,before-1); TEST.eq(FDT.GetState().routes[1].zeroTurns,1)
          TEST.eq(TEST.food(TEST.sender),0); TEST.eq(TEST.food(TEST.receiver),1)
        """)

    def test_gold_disables_newest_then_recovers(self) -> None:
        self.run_lua("""
          assert(FDT.Create(0,{senderCity=1,receiverCity=2,amount=5}))
          assert(FDT.Create(0,{senderCity=1,receiverCity=3,amount=3}))
          Players[0].gold=3; assert(TEST.advance())
          local routes=FDT.GetState().routes
          TEST.eq(routes[1].flow,5); TEST.eq(routes[1].switchedOff,false)
          TEST.eq(routes[2].flow,0); TEST.eq(routes[2].switchedOff,true)
          TEST.eq(Players[0].gold,0); TEST.eq(routes[2].zeroTurns,1)
          Players[0].gold=100; assert(TEST.advance())
          TEST.eq(FDT.GetState().routes[2].flow,3); TEST.eq(FDT.GetState().routes[2].zeroTurns,0)
          TEST.eq(Players[0].gold,95)
        """)

    def test_gold_zero_does_not_overdraw_and_notice_does_not_repeat(self) -> None:
        self.activate()
        self.run_lua("""
          Players[0].gold=0; assert(TEST.advance()); assert(TEST.advance())
          TEST.eq(Players[0].gold,0); TEST.eq(TEST.food(TEST.sender),8); TEST.eq(TEST.food(TEST.receiver),1)
          TEST.eq(TEST.countNotices("switched off"),1)
        """)

    def test_ten_consecutive_zero_turns_remove_route(self) -> None:
        self.activate()
        self.run_lua("""
          TEST.sender.base=0
          for i=1,9 do assert(TEST.advance()); TEST.eq(#FDT.GetState().routes,1) end
          assert(TEST.advance()); TEST.eq(#FDT.GetState().routes,0)
          TEST.eq(TEST.food(TEST.receiver),1); TEST.eq(TEST.countNotices("10 turns"),1)
        """)

    def test_flow_recovery_resets_zero_counter(self) -> None:
        self.activate()
        self.run_lua("""
          TEST.sender.base=0; for i=1,9 do assert(TEST.advance()) end
          TEST.sender.base=8; assert(TEST.advance()); TEST.eq(FDT.GetState().routes[1].zeroTurns,0)
          TEST.sender.base=0; assert(TEST.advance()); TEST.eq(FDT.GetState().routes[1].zeroTurns,1)
        """)

    def test_edit_takes_effect_next_turn_preserves_creation_order(self) -> None:
        self.activate()
        self.run_lua("""
          assert(FDT.Edit(0,{routeID=1,amount=2}))
          TEST.eq(FDT.GetState().routes[1].flow,5); TEST.eq(TEST.food(TEST.sender),3)
          TEST.eq(FDT.GetState().routes[1].createdTurn,10)
          assert(TEST.advance()); TEST.eq(FDT.GetState().routes[1].amount,2)
          TEST.eq(TEST.food(TEST.sender),6); TEST.eq(TEST.food(TEST.receiver),3)
        """)

    def test_cancel_removes_applied_effect_immediately(self) -> None:
        self.activate()
        self.run_lua("""
          assert(FDT.Cancel(0,{routeID=1})); TEST.eq(#FDT.GetState().routes,0)
          TEST.eq(TEST.food(TEST.sender),8); TEST.eq(TEST.food(TEST.receiver),1)
          TEST.eq(#FDT.GetState().applied,0)
        """)

    def test_edit_zero_cancels(self) -> None:
        self.activate()
        self.run_lua("assert(FDT.Edit(0,{routeID=1,amount=0})); TEST.eq(#FDT.GetState().routes,0); TEST.eq(TEST.food(TEST.sender),8)")

    def test_duplicate_and_same_city_routes_rejected(self) -> None:
        self.run_lua("""
          assert(not FDT.Create(0,{senderCity=1,receiverCity=1,amount=1}))
          assert(FDT.Create(0,{senderCity=1,receiverCity=2,amount=5}))
          assert(not FDT.Create(0,{senderCity=1,receiverCity=2,amount=1}))
          TEST.eq(#FDT.GetState().routes,1)
        """)

    def test_invalid_amounts_rejected(self) -> None:
        self.run_lua("""
          for _,amount in ipairs({0,-1,1.5,9,math.huge,'5'}) do
            assert(not FDT.Create(0,{senderCity=1,receiverCity=2,amount=amount}))
          end
          assert(not FDT.Create(0,{senderCity=1,receiverCity=2,amount=0/0}))
          TEST.eq(#FDT.GetState().routes,0)
        """)

    def test_ai_nonowner_and_foreign_route_edits_rejected(self) -> None:
        self.run_lua("""
          assert(not FDT.Create(2,{senderCity=1,receiverCity=2,amount=1}))
          assert(not FDT.Create(0,{senderCity=1,receiverCity=4,amount=1}))
          assert(not FDT.Create(1,{senderCity=1,receiverCity=2,amount=1}))
          assert(FDT.Create(0,{senderCity=1,receiverCity=2,amount=5}))
          assert(not FDT.Edit(1,{routeID=1,amount=1})); assert(not FDT.Cancel(1,{routeID=1}))
          TEST.eq(FDT.GetState().routes[1].amount,5)
          for _,notice in ipairs(TEST.notifications) do assert(notice.owner~=2) end
        """)

    def test_receiver_capture_cleans_effect_for_new_owner(self) -> None:
        self.activate()
        self.run_lua("""
          TEST.receiver.owner=1; TEST.receiver.id=22
          assert(TEST.advance()); TEST.eq(#FDT.GetState().routes,0)
          TEST.eq(TEST.food(TEST.sender),8); TEST.eq(TEST.food(TEST.receiver),1)
          TEST.eq(Players[1].gold,100)
        """)

    def test_capture_engine_removes_dummy_buildings_before_cleanup(self) -> None:
        self.activate()
        self.run_lua("""
          TEST.receiver.owner=1; TEST.receiver.id=22; TEST.receiver.buildings={}
          assert(TEST.advance()); TEST.eq(#FDT.GetState().routes,0)
          TEST.eq(TEST.food(TEST.sender),8); TEST.eq(TEST.food(TEST.receiver),1)
          TEST.eq(#FDT.GetState().applied,0)
        """)

    def test_engine_building_exception_rolls_back_without_gold_charge(self) -> None:
        self.run_lua("""
          assert(FDT.Create(0,{senderCity=1,receiverCity=2,amount=5}))
          TEST.receiver.throwOnCreate=true; TEST.turn=11
          assert(not FDT.ProcessTurn(11)); TEST.eq(Players[0].gold,100)
          TEST.eq(TEST.food(TEST.sender),8); TEST.eq(TEST.food(TEST.receiver),1)
          TEST.eq(FDT.GetState().lastProcessedTurn,-1)
        """)

    def test_missing_invalid_cities_and_spoofed_owner_rejected(self) -> None:
        self.run_lua("""
          assert(not FDT.Create(0,{receiverCity=2,amount=1}))
          assert(not FDT.Create(0,{senderCity=999,receiverCity=2,amount=1}))
          assert(not FDT.Create(1,{owner=0,senderCity=1,receiverCity=2,amount=1}))
          assert(not FDT.Create(0,{senderCity=1,receiverCity=2}))
          assert(not FDT.Cancel(0,{routeID=999})); assert(not FDT.Edit(0,{routeID=999,amount=1}))
          TEST.eq(#FDT.GetState().routes,0)
        """)

    def test_sender_capture_cleans_negative_effect(self) -> None:
        self.activate()
        self.run_lua("""
          TEST.sender.owner=1; TEST.sender.id=21; assert(TEST.advance())
          TEST.eq(#FDT.GetState().routes,0); TEST.eq(TEST.food(TEST.sender),8); TEST.eq(TEST.food(TEST.receiver),1)
        """)

    def test_razed_city_cleans_surviving_endpoint(self) -> None:
        self.activate()
        self.run_lua("""
          TEST.receiver.removed=true; assert(TEST.advance())
          TEST.eq(#FDT.GetState().routes,0); TEST.eq(TEST.food(TEST.sender),8)
        """)

    def test_reused_city_id_does_not_inherit_route(self) -> None:
        self.activate()
        self.run_lua("""
          TEST.sender.removed=true
          local replacement=TEST.city(0,1,20,20,9); assert(TEST.advance())
          TEST.eq(#FDT.GetState().routes,0); TEST.eq(TEST.food(replacement),9); TEST.eq(TEST.food(TEST.receiver),1)
        """)

    def test_cancel_one_route_preserves_other_route_effect(self) -> None:
        self.run_lua("""
          assert(FDT.Create(0,{senderCity=1,receiverCity=2,amount=5}))
          assert(FDT.Create(0,{senderCity=1,receiverCity=3,amount=3})); assert(TEST.advance())
          assert(FDT.Cancel(0,{routeID=1}))
          TEST.eq(TEST.food(TEST.sender),5); TEST.eq(TEST.food(TEST.receiver),1); TEST.eq(TEST.food(TEST.third),5)
        """)

    def test_same_turn_callback_cannot_double_charge(self) -> None:
        self.activate()
        self.run_lua("""
          local gold=Players[0].gold
          assert(not FDT.ProcessTurn(TEST.turn)); TEST.eq(Players[0].gold,gold)
        """)

    def test_reload_keeps_state_and_turn_idempotence(self) -> None:
        self.activate()
        self.lua.execute(GAMEPLAY.read_text(encoding="utf-8"))
        self.run_lua("""
          TEST.eq(#FDT.GetState().routes,1); TEST.eq(TEST.food(TEST.sender),3)
          local gold=Players[0].gold; assert(not FDT.ProcessTurn(TEST.turn)); TEST.eq(Players[0].gold,gold)
          assert(TEST.advance()); TEST.eq(TEST.food(TEST.sender),3); TEST.eq(Players[0].gold,gold-3)
        """)

    def test_building_adapter_supports_both_signs_and_large_aggregates(self) -> None:
        self.run_lua("""
          assert(FDT.ApplyCityFood(TEST.sender,-1234)); TEST.eq(TEST.food(TEST.sender),8-1234)
          assert(FDT.ApplyCityFood(TEST.sender,1048577)); TEST.eq(TEST.food(TEST.sender),8+1048577)
          assert(FDT.ApplyCityFood(TEST.sender,0)); TEST.eq(TEST.food(TEST.sender),8)
          assert(not FDT.ApplyCityFood(TEST.sender,2097152)); TEST.eq(TEST.food(TEST.sender),8)
        """)

    def test_failed_yield_adapter_does_not_charge_or_advance(self) -> None:
        self.run_lua("""
          assert(FDT.Create(0,{senderCity=1,receiverCity=2,amount=5}))
          TEST.effectBroken=true; TEST.turn=11
          assert(not FDT.ProcessTurn(11)); TEST.eq(Players[0].gold,100)
          TEST.eq(FDT.GetState().routes[1].flow,0); TEST.eq(FDT.GetState().lastProcessedTurn,-1)
          TEST.effectBroken=false; assert(FDT.ProcessTurn(11)); TEST.eq(Players[0].gold,97)
        """)

    def test_missing_data_fails_before_charging(self) -> None:
        self.run_lua("""
          assert(FDT.Create(0,{senderCity=1,receiverCity=2,amount=5}))
          GameInfo.Buildings.BUILDING_FDT_FOOD_P_1=nil; TEST.turn=11
          assert(not FDT.ProcessTurn(11)); TEST.eq(Players[0].gold,100)
          TEST.eq(TEST.food(TEST.sender),8); TEST.eq(TEST.food(TEST.receiver),1)
        """)

    def test_notifications_target_only_owner(self) -> None:
        self.activate()
        self.run_lua("for _,notice in ipairs(TEST.notifications) do TEST.eq(notice.owner,0) end")

    def test_mixed_players_have_independent_budgets_and_ai_cannot_create(self) -> None:
        self.run_lua("""
          local secondSender=TEST.city(1,11,30,30,8)
          local secondReceiver=TEST.city(1,12,32,30,1)
          TEST.city(2,21,40,40,8); TEST.city(2,22,42,40,1)
          Players[0].gold=10; Players[1].gold=0
          assert(FDT.Create(0,{senderCity=1,receiverCity=2,amount=5}))
          assert(FDT.Create(1,{senderCity=11,receiverCity=12,amount=4}))
          assert(not FDT.Create(2,{senderCity=21,receiverCity=22,amount=1}))
          assert(TEST.advance()); TEST.eq(#FDT.GetState().routes,2)
          TEST.eq(Players[0].gold,7); TEST.eq(Players[1].gold,0); TEST.eq(Players[2].gold,100)
          TEST.eq(TEST.food(TEST.sender),3); TEST.eq(TEST.food(secondSender),8)
          TEST.eq(FDT.GetState().routes[2].switchedOff,true)
          Players[1].gold=10; assert(TEST.advance())
          TEST.eq(Players[0].gold,4); TEST.eq(Players[1].gold,8)
          TEST.eq(TEST.food(secondReceiver),5)
        """)

    def test_malformed_city_ids_never_reach_native_lookup(self) -> None:
        self.run_lua("""
          TEST.strictNativeIDs=true
          for _,bad in ipairs({-1,1.5,math.huge,-math.huge,0/0,'1',false}) do
            assert(not FDT.Create(0,{senderCity=bad,receiverCity=2,amount=1}))
            assert(not FDT.Create(0,{senderCity=1,receiverCity=bad,amount=1}))
          end
          assert(not FDT.Create(0,{receiverCity=2,amount=1}))
          TEST.eq(#FDT.GetState().routes,0)
        """)

    def test_opposing_routes_do_not_create_extra_available_food(self) -> None:
        self.activate()
        self.run_lua("""
          assert(FDT.Create(0,{senderCity=2,receiverCity=1,amount=1}))
          for i=1,3 do
            assert(TEST.advance())
            TEST.eq(TEST.food(TEST.sender),4); TEST.eq(TEST.food(TEST.receiver),5)
            TEST.eq(FDT.GetAvailableSurplus(TEST.sender),8); TEST.eq(FDT.GetAvailableSurplus(TEST.receiver),1)
            assert(not FDT.Edit(0,{routeID=2,amount=2}))
          end
        """)

    def test_version_matches_manifest_and_approved_development_version(self) -> None:
        self.assertEqual(self.lua.globals().FDT_Core.VERSION, "0.1.0")
        for folder, expected in (("FDT", "0.1.0"), ("FDT_Dev", "0.1.0.1")):
            root = ET.parse(ROOT / folder / (folder + ".modinfo")).getroot()
            self.assertIn(f"Version {expected}.", root.findtext("./Properties/Description", ""))


if __name__ == "__main__":
    from test_tools import ToolingTests
    from test_ui_dev import UIDevTests
    unittest.main(verbosity=2)
