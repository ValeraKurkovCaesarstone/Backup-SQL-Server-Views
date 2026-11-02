-- =====================================================================================
-- XXCS_BI_OM_DELIVERIES_1006_V3   (performance rewrite of XXCS_BI_OM_DELIVERIES_1006_V2)
-- Run as APPS.  V2 is NOT touched.  Same output columns, same names, same order.
--
-- WHAT CHANGED vs V2
--  1. INVOICES inline view: removed the join to OE_ORDER_LINES_ALL / OE_ORDER_HEADERS_ALL
--     (it forced two full index scans of a 2.9M-row table; the outer query already matches
--     invoices on line id + order number).
--  2. Report window is now written as sysdate expressions (trunc(sysdate)-600 .. sysdate+1)
--     instead of xxcs_session_param_pkg.get_session_param_date(1/2), so the optimizer can see
--     the real range.  >>> The 600-day window is now defined IN THIS VIEW. <<<
--  3. item_cat and BI_ITEM_DIME_CAT only read master/validation-organization rows
--     (new CTE master_orgs).  V2 scanned MTL_ITEM_CATEGORIES for every organization and
--     materialised ~100 MB into TEMP, but only ever used the master-org rows.
--  4. inv_convert.inv_um_convert is evaluated ONCE per row (UOM_FACTOR) instead of up to 8x.
--  5. ROW_NUMBER() and the reservation SUM() window are computed once (RN, SUM_RES_QTY)
--     instead of being repeated ~15 times in the select list.
--  6. Forwarder and Item_Org_Source function calls are wrapped in scalar subqueries so Oracle
--     caches results for repeated inputs.
--  7. Removed the unused CTE my_orgn (dead code).
--  8. DETERMINISTIC TIE-BREAK for RN_BY_OE_LINE.  A delivery line invoiced twice (an Intercompany
--     invoice plus a customer-facing invoice) produced two rows with the same DELIVERY_DETAIL_ID, and
--     Oracle picked the RN = 1 row arbitrarily, so ORD_QNTY / INV_QTY / NOT_RES moved between invoices
--     from run to run (also in V2).  Rule now: non-Intercompany invoice first, then earliest invoice
--     date, then lowest invoice number.  To make the Intercompany invoice carry the quantities instead,
--     change  NVL(d.AR_IS_INTERCO, 0)  to  NVL(d.AR_IS_INTERCO, 0) DESC  in the ROW_NUMBER() below.
--
-- NOT CHANGED ON PURPOSE (behaviour-preserving)
--  * regexp_replace cleaning of all text columns (identical expressions).
--  * The outer filter (delivery_status / last_update_date) still has to be applied by the
--    caller AFTER the window functions.  Pushing it into the branches would change which row
--    gets RN = 1 and therefore which row carries the quantities.
--  * Branch 1 sets SITE and TRANSPORTER_IN_ISRAEL both from wnd.TP_ATTRIBUTE1, while branch 2
--    uses TP_ATTRIBUTE1 / TP_ATTRIBUTE2.  Looks like a copy/paste slip in branch 1 - left as is.
--
-- BEFORE CREATING, run this once (checks the function used by master_orgs):
--   select ou.organization_id,
--          oe_sys_parameters.value('MASTER_ORGANIZATION_ID', ou.organization_id) master_org
--     from hr_operating_units ou;
--   -> if it raises an error for some operating unit, see the fallback note at master_orgs.
-- =====================================================================================
CREATE OR REPLACE VIEW XXCS_BI_OM_DELIVERIES_1006_V3 AS
select DLV.CUSTOMER_NUMBER CUSTOMER_NO,
       regexp_replace(regexp_replace(DLV.CUSTOMER_NAME, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') CUSTOMER_NAME,
       DLV.ORDER_NUMBER ORDER_NUMBER,
       DLV.ORDER_LINE ORDER_LINE,
       initcap(DLV.ORDER_STATUS) ORDER_STATUS,
       DLV.ORGANIZATION_CODE ORG,
       DLV.ISRAEL_REQUEST_DATE ISRAEL_REQ_DATE,
       TRUNC(DLV.REQUEST_DATE) REQ_DATE,
       DLV.ORDER_LINE_STATUS ORDER_LINE_STATUS,
       regexp_replace(regexp_replace( DLV.CUST_PO_NUMBER, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') CUST_PO_NO,
       regexp_replace(regexp_replace( DLV.SHIP_TO_LOCATION, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') SHIP_TO_LOCATION_NAME,
       regexp_replace(regexp_replace( DLV.ITEM_DESCRIPTION, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') ITEM_DESCRIPTION,
       DLV.RN RN_BY_OE_LINE,
       DECODE(DLV.RN, 1, DLV.ORDERED_QUANTITY) ORD_QNTY,
       DECODE(DLV.RN, 1, NVL(DLV.ORDERED_QUANTITY, 0) - NVL(DLV.SHIPPED_QUANTITY, 0)) QTY_NO_DLV,
       regexp_replace(regexp_replace( DLV.DELIVERY, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') DELIVERY,
       DLV.REQUESTED_QUANTITY REQUESTED_QUANTITY,
       CASE WHEN DLV.DELIVERY IS NOT NULL THEN DLV.REQUESTED_QUANTITY END QTY_IN_DELIVERY,
       CASE WHEN DLV.DELIVERY IS NULL THEN DLV.REQUESTED_QUANTITY END QTY_NOT_IN_DELIVERY,
       DLV.DEL_LINE_QTY_CONVERTED DEL_LINE_QTY_CONVERTED,
       DECODE(DLV.RN, 1, DLV.PRIMARY_RESERVATION_QUANTITY / DLV.UOM_FACTOR) RES_QTY,
       DECODE(DLV.RN, 1, (DLV.ORDERED_QUANTITY * DLV.UOM_FACTOR) - (NVL(DLV.PRIMARY_RESERVATION_QUANTITY, 0))) NOT_RES_OLD,
       DECODE(DLV.RN, 1,
              case
                when DLV.ORDER_QUANTITY_UOM like 'B%' then
                 DLV.ORDERED_QUANTITY - (NVL(DLV.PRIMARY_RESERVATION_QUANTITY, 0) / DLV.UOM_FACTOR)
                else
                 (DLV.ORDERED_QUANTITY * DLV.UOM_FACTOR) - (NVL(DLV.PRIMARY_RESERVATION_QUANTITY, 0))
              end) NOT_RES,
       CASE WHEN DLV.ORDER_QUANTITY_UOM LIKE 'B%' THEN
          NVL(DLV.PRIMARY_RESERVATION_QUANTITY, 0) / DLV.UOM_FACTOR
       END BOX_RESERVED,
       DLV.PRIMARY_RESERVATION_QUANTITY,
       CASE WHEN DLV.ORDER_QUANTITY_UOM LIKE 'B%' THEN DLV.UOM_FACTOR ELSE NULL END BOX_QNTY,
       DLV.PROMISE_DATE PROMISE_DATE,
       DLV.EXPLOSION_DATE EXPLOSION_DATE,
       TRUNC(DLV.DELIVERY_DATE) DELIVERY_DATE,
       regexp_replace(regexp_replace( DLV.ROUTING_INSTRUCTIONS, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') CALC_DLV_LINE_STATUS,
       regexp_replace(regexp_replace( DLV.GRP, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') GRP,
       regexp_replace(regexp_replace( DLV.WDD_LOT_NUMBER, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') LOT,
       DLV.LOT_GRADE GRADE,
       DLV.ITEM_UNIT_WEIGHT UNIT_WEIGHT,
       DLV.TOTAL_WEIGHT TOTAL_WEIGHT,
       DLV.ITEM_WEIGHT_UOM_CODE WEIGHT_UOM,
       DECODE(DLV.RN, 1, NVL(DLV.ITEM_UNIT_WEIGHT, 0) * DLV.SUM_RES_QTY) RES_WEIGHT,
       DECODE(DLV.RN, 1,
              ((DLV.ORDERED_QUANTITY * DLV.UOM_FACTOR) - (NVL(DLV.PRIMARY_RESERVATION_QUANTITY, 0))) *
              NVL(DLV.ITEM_UNIT_WEIGHT, 0)) NOT_RESERVED_WEIGHT,
       regexp_replace(regexp_replace( DLV.DELIVERY_REMARKS, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') DELIVERY_REMARKS,
       regexp_replace(regexp_replace( DLV.SEAL_NO, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') SEAL_NO,
       regexp_replace(regexp_replace( DLV.CONTAINER_TYPE, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') CONT_TYPE,
       regexp_replace(regexp_replace( NVL(DLV.DOCK_CODE, DLV.CONTAINER_NO), '[^[:alnum:] -]', ''),'( *[[:punct:]])', '')  DOCK_CODE_OR_CONTAINER,
       DLV.SITE SITE,
       DLV.AR_TRX_DATE INV_DATE,
       DLV.AR_TRX_NUMBER INVOICE,
       DECODE(DLV.RN, 1, DLV.AR_QUANTITY_INVOICED) INV_QTY,
       DLV.CLOSING_DATE CLOSING_DATE,
       regexp_replace(regexp_replace( DLV.MAIN_DELIVERY, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') MAIN_DELIVERY,
       regexp_replace(regexp_replace( DLV.PICK_RELEASED_STATUS_MEANING, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') DLV_LINE_STATUS,
       DLV.ITEM_CODE ITEM_CODE,
       DLV.ITEM_TYPE ITEM_TYPE,
       DLV.ORDER_QUANTITY_UOM ORDER_QUANTITY_UOM,
       regexp_replace(regexp_replace( DLV.PORT_OF_DESTINATION, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') PORT_OF_DESTINATION,
       regexp_replace(regexp_replace( DLV.GLB_PORT_DEST_MEANING, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') GLB_PORT_DEST_MEANING,
       regexp_replace(regexp_replace( DLV.GLB_PORT_DEST_DESCRIPTION, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') GLB_PORT_DEST_DESCRIPTION,
       regexp_replace(regexp_replace( DLV.PORT_OF_DISCHARGE, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') PORT_OF_DISCHARGE,
       regexp_replace(regexp_replace( DLV.GLB_PORT_DIS_MEANING, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') GLB_PORT_DIS_MEANING,
       regexp_replace(regexp_replace( DLV.GLB_PORT_DIS_DESCRIPTION, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') GLB_PORT_DIS_DESCRIPTION,
       DLV.BL_DATE BL_DATE,
       regexp_replace(regexp_replace( DLV.VESSEL_NAME, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') VESSEL_NAME,
       DLV.FREIGHT_TERMS_CODE FREIGHT_TERMS_CODE,
       regexp_replace(regexp_replace( DLV.SHIPPING_COMPANY, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') SHIPPING_COMPANY,
       DLV.FOB,
       -----------------------
       regexp_replace(regexp_replace( DLV.ADDRESS1, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') ADDRESS1,
       regexp_replace(regexp_replace( DLV.ADDRESS2, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') ADDRESS2,
       DLV.CITY,
       DLV.COUNTRY,
       regexp_replace(regexp_replace( DLV.ADDRESS_LINES_PHONETIC, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') ADDRESS_LINES_PHONETIC,
       DLV.CONFIRM_DATE,
       initcap(DLV.DELIVERY_STATUS_CODE) DELIVERY_STATUS_CODE,
       DLV.DELIVERY_STATUS,
       DLV.CANONICAL_CLOSING_DATE,
       DLV.LINE_NUMBER,
       DLV.SHIP_NUMBER,
       DECODE(DLV.RN, 1,
              NVL(DLV.ORDERED_QUANTITY, 0) -
              (NVL(DLV.PRIMARY_RESERVATION_QUANTITY, 0) / DLV.UOM_FACTOR)) NOT_RES_QTY_BY_OE_LINE_OE_UOM,
       DECODE(DLV.RN, 1, (DLV.ORDERED_QUANTITY * DLV.UOM_FACTOR)) ORDERED_QNTY_BY_OE_LINE_PR_UOM,
       DECODE(DLV.RN, 1, DLV.PRIMARY_RESERVATION_QUANTITY) RESERVATION_QUANTITY_IN_PR_UOM,
       DLV.REQUESTED_CANCELLED_QUANTITY,
       DLV.SHIPPED_QUANTITY,
       DLV.ITEM_PRIMARY_UOM_CODE,
       DLV.REQUESTED_QUANTITY_UOM,
       regexp_replace(regexp_replace( DLV.SOURCE_HEADER_TYPE_NAME, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') SOURCE_HEADER_TYPE_NAME,
       regexp_replace(regexp_replace( DLV.CONTAINER_NO, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') CONTAINER_NO,
       regexp_replace(regexp_replace( DLV.DOCK_CODE, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') DOCK_CODE,
       regexp_replace(regexp_replace( DLV.TRANSPORTER_IN_ISRAEL, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') TRANSPORTER_IN_ISRAEL,
       regexp_replace(regexp_replace( DLV.CANADA_PROJECT, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') CANADA_PROJECT,
       DLV.WEIGHT_UOM_CODE,
       DLV.SOURCE_CODE,
       DLV.RELEASED_STATUS,
       DLV.MO_NUMBER,
       DLV.MO_LINE,
       DLV.DEL_LINE_CREATE_DATE,
       DLV.DEL_CREATE_DATE,
       DLV.OE_OPERATING_UNIT_NAME,
       DLV.OE_IN_INTERFACE,
       regexp_replace(regexp_replace( DLV.ORDER_TRANSACTION_TYPE, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') ORDER_TRANSACTION_TYPE,
       regexp_replace(regexp_replace( DLV.ORIG_SYS_DOCUMENT_REF, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') ORIG_SYS_DOCUMENT_REF,
       regexp_replace(regexp_replace( DLV.CS_COMMENTS, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') CS_COMMENTS,
       regexp_replace(regexp_replace( DLV.DELIVERY_HOLD, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') DELIVERY_HOLD,
       DLV.HAZARD_CLASS_CODE,
       regexp_replace(regexp_replace( DLV.HAZARD_CLASS_DESCRIPTION, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') HAZARD_CLASS_DESCRIPTION,
       regexp_replace(regexp_replace( DLV.CAT_CATEGORY_SET_NAME, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') CAT_CATEGORY_SET_NAME,
       DLV.CSI_SIZE,
       regexp_replace(regexp_replace( DLV.CSI_SIZE_DETAILS, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') CSI_SIZE_DETAILS,
       DLV.CSI_COLOR,
       regexp_replace(regexp_replace( DLV.CSI_COLOR_DETAILS, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') CSI_COLOR_DETAILS,
       DLV.CSI_THICK,
       regexp_replace(regexp_replace( DLV.CSI_THICK_DETAILS, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') CSI_THICK_DETAILS,
       DLV.CSI_FINISH,
       regexp_replace(regexp_replace( DLV.CSI_FINISH_DETAILS, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') CSI_FINISH_DETAILS,
       DLV.CSI_FAMILY,
       regexp_replace(regexp_replace( DLV.CSI_FAMILY_DETAILS, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') CSI_FAMILY_DETAILS,
       DLV.CSI_CLASSIFICATION,
       regexp_replace(regexp_replace( DLV.CSI_CLASSIFICATION_DETAILS, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') CSI_CLASSIFICATION_DETAILS,
       DLV.FROM_REPORT_DATE,
       DLV.TO_REPORT_DATE,
       DLV.HAZARD_CLASS_ID,
       DLV.INVENTORY_ITEM_ID,
       DLV.SOURCE_HEADER_TYPE_ID,
       DLV.ORG_ID,
       DLV.DEMAND_SOURCE_LINE_ID,
       DLV.DELIVERY_DETAIL_ID,
       DLV.DELIVERY_ID,
       DLV.ORDER_HEADER_ID,
       DLV.ORDER_LINE_ID,
       DLV.CUSTOMER_ID,
       DLV.ORGANIZATION_ID,
       DLV.delivery_planned_flag_Code,
       DLV.Delivery_Planned_Flag,
       DLV.oola_ship_from_org_id,
       DLV.oola_ship_from_org_code,
       regexp_replace(regexp_replace( DLV.inventory_item_category, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') inventory_item_category,
       DLV.oe_schedule_ship_date,
       DLV.oe_schedule_arrival_date
       ---------------
      ,
       DLV.CODE_43_DATE,
       DLV.CODE_42_DATE,
       regexp_replace(regexp_replace( DLV.CONTAINER_NUMBER, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') CONTAINER_NUMBER,
       regexp_replace(regexp_replace( DLV.TSHIP_PORT, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') TSHIP_PORT,
       regexp_replace(regexp_replace( DLV.TSHIP_ETA, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') TSHIP_ETA,
       regexp_replace(regexp_replace( DLV.TSHIP_ETD, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') TSHIP_ETD,
       regexp_replace(regexp_replace( DLV.FINAL_PORT_ETA, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') FINAL_PORT_ETA,
       regexp_replace(regexp_replace( DLV.FINAL_DEST_ETA, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') FINAL_DEST_ETA,
       DLV.STATUS,
       DLV.STATUS_DATE,
       DLV.CS_CLOSING_DATE,
       DLV.ORDER_CREATION_DATE,
       DLV.ORDER_LINE_CREATION_DATE,
       DLV.ORDER_BOOKED_DATE,
       DLV.ORDERED_DATE,
       regexp_replace(regexp_replace( DLV.OE_LINE_SHIPPING_INSTRUCTIONS, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') OE_LINE_SHIPPING_INSTRUCTIONS,
       DLV.ORDER_TYPE_ID,
       DLV.ORDER_LINE_TYPE_ID,
       DLV.ORDER_LINE_TRANSACTION_TYPE,
       DLV.OE_UNIT_LIST_PRICE,
       DLV.OE_UNIT_SELLING_PRICE,
       regexp_replace(regexp_replace( DLV.OE_LINE_PACKING_INSTRUCTIONS, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') OE_LINE_PACKING_INSTRUCTIONS,
       DLV.OE_TRANSACTIONAL_CURR_CODE,
       DLV.SOURCE_DOCUMENT_TYPE_ID,
       regexp_replace(regexp_replace( DLV.DESTINATION_SUBS, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') DESTINATION_SUBS,
       regexp_replace(regexp_replace( DLV.DESTINATION_ORGN, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') DESTINATION_ORGN,
       DLV.FIRST_SHIP_DATE,
       DLV.SAIL_DATE,
       regexp_replace(regexp_replace( DLV.CUSTOMS_BROKER, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') CUSTOMS_BROKER,
       dlv.oola_subinventory,
       regexp_replace(regexp_replace( DLV.subinventory_description, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') subinventory_description,
       dlv.gross_weight,
       regexp_replace(regexp_replace( DLV.Forwarder, '[^[:alnum:] -]', ''),'( *[[:punct:]])', '') Forwarder,
       dlv.Booking_Number,
       dlv.Item_Org_Source,
       dlv.last_update_date
  from (select x.*,
               -- change 4: one conversion call per row, only where V2 would have called it
               case
                 when x.RN = 1 or x.ORDER_QUANTITY_UOM like 'B%' then
                  inv_convert.inv_um_convert(x.INVENTORY_ITEM_ID,
                                             x.ORDER_QUANTITY_UOM,
                                             x.REQUESTED_QUANTITY_UOM)
               end UOM_FACTOR
          from (select d.*,
                       -- change 5: window functions computed once
                       ROW_NUMBER() OVER(PARTITION BY d.ORDER_HEADER_ID, d.LINE_NUMBER, d.SHIP_NUMBER
                                         ORDER BY d.ORDER_HEADER_ID, d.LINE_NUMBER, d.SHIP_NUMBER, d.DELIVERY_DETAIL_ID,
                                                  NVL(d.AR_IS_INTERCO, 0), d.AR_TRX_DATE, d.AR_TRX_NUMBER) RN,
                       SUM(NVL(d.PRIMARY_RESERVATION_QUANTITY, 0))
                         OVER(PARTITION BY d.ORDER_HEADER_ID, d.ORDER_LINE_ID) SUM_RES_QTY
                  from (with shipping_orgn as (select from_organization_id,
                                      from_organization_code,
                                      cot_operating_unit
                                 from (select msnv.from_organization_code,
                                              msnv.from_organization_name,
                                              hof.name                    from_operating_unit,
                                              msnv.to_organization_code,
                                              msnv.to_organization_name,
                                              msnv.from_organization_id,
                                              msnv.to_organization_id,
                                              hot.name                    to_operating_unit,
                                              cof.operating_unit          cof_operating_unit,
                                              cot.operating_unit          cot_operating_unit
                                         from mtl_shipping_network_view    msnv,
                                              cst_organization_definitions cot,
                                              cst_organization_definitions cof,
                                              hr_operating_units           hof,
                                              hr_operating_units           hot
                                        where 1 = 1
                                          and msnv.to_organization_id =
                                              cot.organization_id
                                          and cot.user_definition_enable_date <=
                                              trunc(sysdate)
                                          and nvl(cot.disable_date,
                                                  trunc(sysdate)) >=
                                              trunc(sysdate)
                                             ----------------------------------------------------------------
                                          and msnv.from_organization_id =
                                              cof.organization_id
                                          and cof.user_definition_enable_date <=
                                              trunc(sysdate)
                                          and nvl(cof.disable_date,
                                                  trunc(sysdate)) >=
                                              trunc(sysdate)
                                             -----------------------------------------------------------------
                                          And cof.operating_unit =
                                              hof.organization_id
                                          And cot.operating_unit =
                                              hot.organization_id
                                          and cof.operating_unit in (81,221,201,121,561)
                                             )
                               minus
                               select null, null, null
                                 from dual)
      -- change 3: master / item-validation organizations only (a few rows).
      -- FALLBACK if oe_sys_parameters.value raises for some operating unit:
      --   select organization_id master_org_id from mtl_parameters where organization_id = master_organization_id
      , master_orgs as (select master_org_id
                          from (select distinct to_number(oe_sys_parameters.value('MASTER_ORGANIZATION_ID',
                                                                                  ou.organization_id)) master_org_id
                                  from hr_operating_units ou)
                         where master_org_id is not null)
      , item_cat as
        -- TIEBREAK FIX: a small number of items resolve to more than one
        -- category row; ROW_NUMBER()=1 keeps exactly one per item/org.
        (select Item_category,
                Item_category_Segment1,
                cat_INVENTORY_ITEM_ID,
                cat_ORGANIZATION_ID,
                CATEGORY_SET_NAME
           from (select mic.category_concat_segs Item_category,
                        mic.SEGMENT1             Item_category_Segment1,
                        mic.inventory_item_id    cat_INVENTORY_ITEM_ID,
                        mic.organization_id      cat_ORGANIZATION_ID,
                        mcv.CATEGORY_SET_NAME,
                        ROW_NUMBER() OVER(PARTITION BY mic.inventory_item_id,
                                                        mic.organization_id
                                              ORDER BY mic.category_id) rn
                   from mtl_category_sets_vl  mcv,
                        mtl_item_categories_v mic
                  where 1 = 1
                    and mic.category_set_id =
                        mcv.category_set_id
                    And mcv.CATEGORY_SET_NAME =
                        'Inventory'
                    and mic.organization_id in (select master_org_id from master_orgs))
          where rn = 1)
      , CS_RESERVATIONS AS
        (Select sum(mr.primary_reservation_quantity) mr_primary_reservation_qnty,
                mr.organization_id mr_organization_id,
                mr.inventory_item_id mr_inventory_item_id,
                mr.lot_number mr_lot_number,
                mr.demand_source_line_id mr_demand_source_line_id,
                mr.reservation_uom_code mr_reservation_uom_code
           From mtl_reservations mr
          where 1 = 1
          Group By mr.organization_id,
                   mr.inventory_item_id,
                   mr.lot_number,
                   mr.demand_source_line_id,
                   mr.reservation_uom_code)
      , CS_RESERVATIONS_NL AS
        (Select sum(cr.mr_primary_reservation_qnty) mr_primary_reservation_qnty,
                cr.mr_organization_id mr_organization_id,
                cr.mr_inventory_item_id mr_inventory_item_id,
                cr.mr_demand_source_line_id mr_demand_source_line_id,
                cr.mr_reservation_uom_code mr_reservation_uom_code
           From CS_RESERVATIONS cr
          Group By cr.mr_organization_id,
                   cr.mr_inventory_item_id,
                   cr.mr_demand_source_line_id,
                   cr.mr_reservation_uom_code)
      , CSI_SEGMENTS_MEANING AS
        -- FANOUT FIX: this lookup is joined SIX times inside BI_ITEM_DIME_CAT
        (select FLEX_VALUE, FV_MEANING, FV_DESCRIPTION, FLEX_VALUE_SET_NAME
           from (SELECT FFVL.FLEX_VALUE          FLEX_VALUE,
                        FFVL.FLEX_VALUE_MEANING  FV_MEANING,
                        FFVL.DESCRIPTION         FV_DESCRIPTION,
                        FFVS.FLEX_VALUE_SET_NAME FLEX_VALUE_SET_NAME,
                        ROW_NUMBER() OVER(PARTITION BY FFVS.FLEX_VALUE_SET_NAME,
                                                        FFVL.FLEX_VALUE
                                              ORDER BY FFVL.FLEX_VALUE_MEANING) rn
                   FROM FND_FLEX_VALUES_VL  FFVL,
                        FND_FLEX_VALUE_SETS FFVS
                  Where 1 = 1
                    And FFVL.FLEX_VALUE_SET_ID =
                        FFVS.FLEX_VALUE_SET_ID
                    And FFVS.FLEX_VALUE_SET_NAME IN
                        ('CSI_COLOR',
                         'CSI_THICK',
                         'CSI_SIZE',
                         'CSI_FAMILY',
                         'CSI_FINISH',
                         'CSI_CLASSIFICATION'))
          where rn = 1)
      , BI_ITEM_DIME_CAT as
        -- TIEBREAK FIX: same pattern as item_cat above. ROW_NUMBER()=1 per
        -- inventory_item_id/organization_id resolves duplicate category rows.
        (select cat_INVENTORY_ITEM_ID, cat_ORGANIZATION_ID, cat_CATEGORY_SET_NAME,
                CSI_SIZE, CSI_SIZE_DETAILS, CSI_COLOR, CSI_COLOR_DETAILS,
                CSI_THICK, CSI_THICK_DETAILS, CSI_FINISH, CSI_FINISH_DETAILS,
                CSI_FAMILY, CSI_FAMILY_DETAILS, CSI_CLASSIFICATION, CSI_CLASSIFICATION_DETAILS
           from (select mic.INVENTORY_ITEM_ID cat_INVENTORY_ITEM_ID,
                                     mic.ORGANIZATION_ID cat_ORGANIZATION_ID,
                                     mic.CATEGORY_SET_NAME cat_CATEGORY_SET_NAME,
                                     mic.SEGMENT1 CSI_SIZE,
                                     NVL(CSI_SIZE.FV_DESCRIPTION,
                                         CSI_SIZE.FV_MEANING) CSI_SIZE_DETAILS,
                                     mic.SEGMENT2 CSI_COLOR,
                                     NVL(CSI_COLOR.FV_DESCRIPTION,
                                         CSI_COLOR.FV_MEANING) CSI_COLOR_DETAILS,
                                     mic.SEGMENT3 CSI_THICK,
                                     NVL(CSI_THICK.FV_DESCRIPTION,
                                         CSI_THICK.FV_MEANING) CSI_THICK_DETAILS,
                                     mic.SEGMENT4 CSI_FINISH,
                                     NVL(CSI_FINISH.FV_DESCRIPTION,
                                         CSI_FINISH.FV_MEANING) CSI_FINISH_DETAILS,
                                     mic.SEGMENT5 CSI_FAMILY,
                                     NVL(CSI_FAMILY.FV_DESCRIPTION,
                                         CSI_FAMILY.FV_MEANING) CSI_FAMILY_DETAILS,
                                     mic.SEGMENT6 CSI_CLASSIFICATION,
                                     NVL(CSI_CLASSIFICATION.FV_DESCRIPTION,
                                         CSI_CLASSIFICATION.FV_MEANING) CSI_CLASSIFICATION_DETAILS,
                                     ROW_NUMBER() OVER(PARTITION BY mic.INVENTORY_ITEM_ID,
                                                                     mic.ORGANIZATION_ID
                                                           ORDER BY mic.CATEGORY_ID) rn
                                from mtl_item_categories_v mic,
                                     CSI_SEGMENTS_MEANING  CSI_SIZE,
                                     CSI_SEGMENTS_MEANING  CSI_COLOR,
                                     CSI_SEGMENTS_MEANING  CSI_THICK,
                                     CSI_SEGMENTS_MEANING  CSI_FINISH,
                                     CSI_SEGMENTS_MEANING  CSI_FAMILY,
                                     CSI_SEGMENTS_MEANING  CSI_CLASSIFICATION
                               Where 1 = 1
                                 And mic.CATEGORY_SET_NAME = 'BI_ITEM_DIME'
                                 And mic.ORGANIZATION_ID in (select master_org_id from master_orgs)
                                 And MIC.SEGMENT1 = CSI_SIZE.FLEX_VALUE(+)
                                 And CSI_SIZE.FLEX_VALUE_SET_NAME(+) =
                                     'CSI_SIZE'
                                 And MIC.SEGMENT2 = CSI_COLOR.FLEX_VALUE(+)
                                 And CSI_COLOR.FLEX_VALUE_SET_NAME(+) =
                                     'CSI_COLOR'
                                 And MIC.SEGMENT3 = CSI_THICK.FLEX_VALUE(+)
                                 And CSI_THICK.FLEX_VALUE_SET_NAME(+) =
                                     'CSI_THICK'
                                 And MIC.SEGMENT4 = CSI_FINISH.FLEX_VALUE(+)
                                 And CSI_FINISH.FLEX_VALUE_SET_NAME(+) =
                                     'CSI_FINISH'
                                 And MIC.SEGMENT5 = CSI_FAMILY.FLEX_VALUE(+)
                                 And CSI_FAMILY.FLEX_VALUE_SET_NAME(+) =
                                     'CSI_FAMILY'
                                 And MIC.SEGMENT6 =
                                     CSI_CLASSIFICATION.FLEX_VALUE(+)
                                 And CSI_CLASSIFICATION.FLEX_VALUE_SET_NAME(+) =
                                     'CSI_CLASSIFICATION')
          where rn = 1)
      , code_43 as (select CONTAINER_NUMBER, max(CODE_43_DATE) CODE_43_DATE
                       from (SELECT CONTAINER_NUMBER, CODE_43_DATE
                               FROM (SELECT qc.CONTAINER_NUMBER,
                                            qc.CODE_43_DATE,
                                            qc.creation_date,
                                            MAX(qc.creation_date) OVER(PARTITION BY CONTAINER_NUMBER) AS rmax_date
                                       FROM Q_CONTAINERS_V qc
                                      WHERE qc.CODE_43_DATE is not null
                                        and qc.organization_id = 101)
                              where creation_date = rmax_date
                              group by CONTAINER_NUMBER, CODE_43_DATE)
                      group by CONTAINER_NUMBER)
      , code_42 as (select CONTAINER_NUMBER, max(CODE_42_DATE) CODE_42_DATE
                       from (SELECT CONTAINER_NUMBER, CODE_42_DATE
                               FROM (SELECT qc.CONTAINER_NUMBER,
                                            qc.CODE_42_DATE,
                                            qc.creation_date,
                                            MAX(qc.creation_date) OVER(PARTITION BY CONTAINER_NUMBER) AS rmax_date
                                       FROM Q_CONTAINERS_V qc
                                      WHERE qc.CODE_42_DATE is not null
                                        and qc.organization_id = 101)
                              where creation_date = rmax_date
                              group by CONTAINER_NUMBER, CODE_42_DATE)
                      group by CONTAINER_NUMBER)
      , global_sea_ports as (Select flv.lookup_code global_sea_ports_code,
                                     flv.meaning     global_sea_ports_meaning,
                                     flv.description global_sea_ports_description
                                from fnd_lookup_values flv
                               Where 1 = 1
                                 And flv.lookup_type =
                                     'XXCS_GLOBAL_SEA_PORTS'
                                 and flv.language = 'US')
       ---------------  BRANCH 1: Shipped deliveries
         select 'Shipped' grp,
                ac.CUSTOMER_NUMBER,
                ac.CUSTOMER_NAME,
                hzloc.address1,
                hzloc.address2,
                hzloc.city,
                hzloc.country,
                hzloc.address_lines_phonetic,
                ship_su.location ship_to_location,
                wnd.name Delivery,
                wnd.dock_code dock_code,
                wnd.confirm_date confirm_date,
                wnd.initial_pickup_date delivery_date,
                wnd.shipping_marks Main_delivery,
                wnd.status_code delivery_status_code,
                wl.meaning delivery_status,
                wl_released.MEANING Pick_released_status_meaning,
                wnd.entry_number Closing_date,
                to_CHAR(fnd_date.canonical_to_date(wnd.entry_number),
                        'DD/MM/RRRR') canonical_Closing_date,
                wdd.source_header_number Order_number,
                wdd.source_line_number Order_line,
                oola.flow_status_code order_line_status,
                to_number(substr(wdd.source_line_number,
                                 1,
                                 instr(wdd.source_line_number, '.') - 1)) Line_number,
                to_number(substr(wdd.source_line_number,
                                 instr(wdd.source_line_number, '.') + 1)) ship_number,
                oola.ordered_quantity,
                NULL primary_reservation_quantity,
                oola.cancelled_quantity,
                nvl(wdd.requested_quantity, 0) requested_quantity,
                nvl(wdd.cancelled_quantity, 0) requested_cancelled_quantity,
                nvl(wdd.shipped_quantity, 0) shipped_quantity,
                wdd.requested_quantity_uom,
                wnd.routing_instructions routing_instructions,
                msib.segment1 Item_code,
                msib.description item_description,
                msib.item_type item_type,
                msib.primary_uom_code item_primary_uom_code,
                msib.unit_weight item_unit_weight,
                msib.weight_uom_code item_weight_uom_code,
                wdd.source_header_type_name source_header_type_name,
                wdd.lot_number wdd_lot_number,
                mln.grade_code lot_grade
                ---------------------------------------------------------------
               ,
                null primary_reserv_qty_converted,
                wdd.requested_quantity /
                inv_convert.inv_um_convert(wdd.inventory_item_id,
                                           wdd.src_requested_quantity_uom,
                                           wdd.requested_quantity_uom) Del_Line_Qty_converted,
                wndd.port_of_destination port_of_destination,
                wndd.port_of_discharge port_of_discharge,
                wndd.seal_number seal_no,
                wndd.container_type container_type,
                wndd.container_name container_no,
                wnd.TP_ATTRIBUTE1 site, --fixed by Valeryk 06102022 cr#74201
                wnd.TP_ATTRIBUTE1 transporter_in_israel, --fixed by Valeryk 06102022 cr#74201
                wndd.csc_project Canada_Project,
                wdl.shipper_date BL_date,
                wnd.additional_shipment_info Vessel_Name,
                wnd.freight_terms_code freight_terms_code,
                wnd.problem_contact_reference delivery_remarks,
                wc.freight_code shipping_company,
                wdd.net_weight Total_Weight,
                wdd.weight_uom_code weight_uom_code,
                mp.organization_code,
                ooha.orig_sys_document_ref,
                oola.CUSTOMER_PRODUCTION_LINE cs_comments,
                wnd.attribute7 delivery_hold,
                msib.hazard_class_id hazard_class_id,
                ph.hazard_class hazard_class_code,
                ph.description hazard_class_description
                ------------------
               ,
                oola.order_quantity_uom,
                wdd.source_code,
                wdd.delivery_detail_id,
                wnd.delivery_id,
                wdd.source_header_id order_header_id,
                wdd.source_line_id order_line_id,
                wdd.customer_id,
                wdd.organization_id,
                wdd.released_status,
                wdd.inventory_item_id,
                wdd.source_header_type_id,
                wdd.org_id,
                null demand_source_line_id,
                mtrh.request_number mo_number,
                mtrl.line_number mo_line,
                wdd.creation_date Del_Line_Create_Date,
                wnd.creation_date Del_Create_Date,
                hou.name oe_operating_unit_name,
                INVOICES.AR_TRX_DATE AR_TRX_DATE,
                INVOICES.AR_TRX_NUMBER AR_TRX_NUMBER,
                NULL AR_LINE_NUMBER,
                INVOICES.QUANTITY_INVOICED AR_QUANTITY_INVOICED,
                INVOICES.AR_IS_INTERCO AR_IS_INTERCO,
                rila.interface_line_attribute1 oe_in_interface,
                oola.promise_date,
                oola.explosion_date,
                oola.request_date,
                ooha.cust_po_number,
                ooha.flow_status_code order_status,
                oola.shipment_priority_code Israel_request_date,
                ooha.fob_point_code FOB,
                ot.name order_transaction_type,
                wnd.planned_flag delivery_planned_flag_Code,
                wlk.MEANING Delivery_Planned_Flag,
                oola.ship_from_org_id oola_ship_from_org_id,
                mpl.organization_code oola_ship_from_org_code,
                item_cat.Item_category inventory_item_category,
                oola.schedule_ship_date oe_schedule_ship_date,
                oola.schedule_arrival_date oe_schedule_arrival_date,
                bidc.cat_CATEGORY_SET_NAME,
                bidc.CSI_SIZE,
                bidc.CSI_SIZE_DETAILS,
                bidc.CSI_COLOR,
                bidc.CSI_COLOR_DETAILS,
                bidc.CSI_THICK,
                bidc.CSI_THICK_DETAILS,
                bidc.CSI_FINISH,
                bidc.CSI_FINISH_DETAILS,
                bidc.CSI_FAMILY,
                bidc.CSI_FAMILY_DETAILS,
                bidc.CSI_CLASSIFICATION,
                bidc.CSI_CLASSIFICATION_DETAILS,
                xcv.CODE_43_DATE,
                xcb.CODE_42_DATE,
                wnd.attribute5 CONTAINER_NUMBER,
                FND_DATE.canonical_to_date(wnd.tp_attribute5) Seal_Date,
                wnd.tp_attribute6 TShip_Port,
                FND_DATE.canonical_to_date(wnd.tp_attribute7) TShip_ETA,
                FND_DATE.canonical_to_date(wnd.tp_attribute8) TShip_ETD,
                FND_DATE.canonical_to_date(wnd.tp_attribute10) Final_Port_ETA,
                FND_DATE.canonical_to_date(wnd.tp_attribute11) Final_Dest_ETA,
                wnd.tp_attribute12 Status,
                FND_DATE.canonical_to_date(wnd.tp_attribute13) Status_Date,
                FND_DATE.canonical_to_date(wnd.entry_number) CS_Closing_Date,
                ooha.creation_date order_creation_date,
                oola.creation_date order_line_creation_date,
                ooha.booked_date order_booked_date,
                ooha.ordered_date ordered_date,
                oola.shipping_instructions oe_line_shipping_instructions,
                ooha.order_type_id order_type_id,
                oola.line_type_id order_line_type_id,
                oe_types_lines.name order_line_transaction_type,
                oola.unit_list_price oe_unit_list_price,
                oola.unit_selling_price oe_unit_selling_price,
                oola.packing_instructions oe_line_packing_instructions,
                ooha.transactional_curr_code oe_transactional_curr_code,
                oola.source_document_type_id,
                case
                  when oola.source_document_type_id = 10 then
                   (select rtrim(REGEXP_REPLACE(LISTAGG(rl.destination_subinventory,
                                                        ';') within
                                                group(order by
                                                      RH.REQUISITION_HEADER_ID),
                                                '([^;]*)(;\1)+($|;)',
                                                '\1\3'),
                                 ';') released_status
                      FROM po_requisition_headers_all rh,
                           po_requisition_lines_all   rl
                     Where 1 = 1
                       And RH.REQUISITION_HEADER_ID = rl.requisition_header_id
                       And rh.requisition_header_id = ooha.source_document_id
                       And rl.requisition_line_id =
                           oola.source_document_line_id)
                END destination_subs,
                case
                  when oola.source_document_type_id = 10 then
                   (select rtrim(REGEXP_REPLACE(LISTAGG(mp.organization_code,
                                                        ';') within
                                                group(order by
                                                      RH.REQUISITION_HEADER_ID),
                                                '([^;]*)(;\1)+($|;)',
                                                '\1\3'),
                                 ';') released_status
                      FROM po_requisition_headers_all rh,
                           po_requisition_lines_all   rl,
                           mtl_parameters             mp
                     Where 1 = 1
                       And RH.REQUISITION_HEADER_ID = rl.requisition_header_id
                       And rh.requisition_header_id = ooha.source_document_id
                       And rl.destination_organization_id = mp.organization_id)
                END destination_orgn,
                glb_port_dest.global_sea_ports_meaning glb_port_dest_meaning,
                glb_port_dest.global_sea_ports_description glb_port_dest_description
               ,
                glb_port_dis.global_sea_ports_meaning glb_port_dis_meaning,
                glb_port_dis.global_sea_ports_description glb_port_dis_description,
                oola_dfv.first_ship_date                        first_ship_date,
                TO_DATE(wnd.TP_ATTRIBUTE5, 'YYYY/MM/DD HH24:MI:SS')   sail_date,  --fixed by Valeryk 06102022 cr#74201
                ship_cas.attribute11                            customs_broker,
                trunc(sysdate) - 600                            From_report_date,   -- change 2
                sysdate                                         To_report_date,     -- change 2
                oola.subinventory                oola_subinventory,
                msv.description                  subinventory_description,
                wdd.gross_weight                 gross_weight,
                -- change 6: cached per delivery_id
                NVL((select xxcs_oem_direct_po_util_pkg.xxoem_actual_forwarder_f(wnd.delivery_id) from dual),
                    ship_cas.attribute11) Forwarder,
                wnd.waybill Booking_Number,
                -- change 6: cached per item/org
                (select XXCS_PLN_UTILS.GET_SOURCEING_RULE(0,msib.inventory_item_id,msib.organization_id) from dual) Item_Org_Source,
                wnd.last_update_date
           from wsh_delivery_details wdd,
                oe_order_lines_all oola,
                oe_order_lines_all_dfv     oola_dfv,
                oe_order_headers_all ooha,
                ar_customers ac,
                hz_cust_site_uses_all ship_su,
                hz_cust_acct_sites_all ship_cas,
                hz_locations hzloc,
                BI_ITEM_DIME_CAT bidc,
                wsh_lookups wl_released,
                wsh_lookups wl,
                wsh_delivery_assignments wda,
                wsh_new_deliveries wnd,
                mtl_system_items_b msib,
                po_hazard_classes ph,
                mtl_lot_numbers mln,
                wsh_new_deliveries_dfv wndd,
                global_sea_ports glb_port_dest,
                global_sea_ports glb_port_dis,
                wsh_delivery_legs wdl,
                wsh_carriers wc,
                mtl_txn_request_headers mtrh,
                mtl_txn_request_lines mtrl,
                mtl_parameters mp,
                hr_operating_units hou,
                OE_TRANSACTION_TYPES_TL ot,
                Ra_Interface_Lines_All rila,
                -- change 1: no join to OE_ORDER_LINES_ALL / OE_ORDER_HEADERS_ALL here.
                -- The outer query already matches on line id (interface_line_attribute6) and order number (sales_order).
                (SELECT rcta.trx_date AR_TRX_DATE,
                        rcta.trx_number AR_TRX_NUMBER,
                        RCTL.SALES_ORDER AR_SALES_ORDER,
                        sum(NVL(RCTL.QUANTITY_INVOICED,
                                RCTL.QUANTITY_CREDITED)) QUANTITY_INVOICED,
                        RCTL.INTERFACE_LINE_ATTRIBUTE6 AR_INTERFACE_LINE_ATTRIBUTE6,
                        MAX(DECODE(RCTT.NAME, 'Intercompany', 1, 0)) AR_IS_INTERCO
                   FROM RA_CUSTOMER_TRX_LINES_ALL RCTL,
                        RA_CUSTOMER_TRX_ALL       RCTA,
                        RA_CUST_TRX_TYPES_ALL     RCTT
                  WHERE 1 = 1
                    AND RCTA.CUSTOMER_TRX_ID = RCTL.CUSTOMER_TRX_ID
                    And RCTA.org_id in (81,221,201,121,561)
                    And RCTT.CUST_TRX_TYPE_ID(+) = RCTA.CUST_TRX_TYPE_ID
                    And RCTT.ORG_ID(+)           = RCTA.ORG_ID
                    AND RCTA.TRX_DATE >= trunc(sysdate) - 600          -- change 2
                    AND RCTA.TRX_DATE <  sysdate + 1                   -- change 2
                  group by rcta.trx_date,
                           RCTL.SALES_ORDER,
                           RCTL.INTERFACE_LINE_ATTRIBUTE6,
                           rcta.trx_number) INVOICES
                ----------
               ,
                mtl_parameters          mpl,
                item_cat                item_cat,
                wsh_lookups             wlk,
                shipping_orgn           shipping_orgn,
                code_43                 xcv,
                code_42                 xcb,
                OE_TRXT_TYPES_NOORGS_VL OE_TYPES_LINES,
                mtl_secondary_inventories   msv
          where 1 = 1
            and wdd.source_line_id = oola.line_id
            and oola.header_id = ooha.header_id
            And oola.rowid  = oola_dfv.row_id (+)
            And ooha.order_type_id = ot.transaction_type_id
            And ot.language = userenv('LANG')
            and wda.delivery_id = wnd.delivery_id --(+)
            and wdd.delivery_detail_id = wda.delivery_detail_id -- (+)
            and wdd.released_status = wl_released.lookup_code(+)
            and wl_released.lookup_type(+) = 'PICK_STATUS'
            and wnd.status_code = wl.lookup_code(+)
            and wl.lookup_type(+) = 'DELIVERY_STATUS'
            and wdd.source_code = 'OE'
            and wdd.released_status in ('C')
            and wdd.inventory_item_id = msib.inventory_item_id
            and wdd.organization_id = msib.organization_id
            and msib.hazard_class_id = ph.HAZARD_CLASS_ID(+)
            and wdd.organization_id = wnd.organization_id
            and wdd.inventory_item_id = mln.inventory_item_id(+)
            and wdd.organization_id = mln.organization_id(+)
            and wdd.lot_number = mln.lot_number(+)
            And wdd.organization_id = wnd.organization_id
            And wdd.organization_id = mp.organization_id
            and wnd.rowid = wndd.row_id(+)
            and wnd.delivery_id = wdl.delivery_id(+)
            and wnd.carrier_id = wc.carrier_id(+)
            and wdd.move_order_line_id = mtrl.line_id(+)
            and mtrl.header_id = mtrh.header_id(+)
            and wnd.customer_id = ac.Customer_id
            and wnd.ultimate_dropoff_location_id = hzloc.location_id
            and oola.ship_to_org_id = ship_su.site_use_id(+)
            and SHIP_su.cust_acct_site_id   = ship_cas.cust_acct_site_id (+)
            and oola.org_id = hou.organization_id
            AND TO_CHAR(WDD.SOURCE_LINE_ID) =
                INVOICES.AR_INTERFACE_LINE_ATTRIBUTE6(+)
            AND WDD.SOURCE_HEADER_NUMBER = INVOICES.AR_SALES_ORDER(+)
            AND to_char(oola.line_id) = rila.interface_line_attribute6(+)
               ----------------------------------------------------------------------------------------------------
            And wdd.inventory_item_id = item_cat.cat_INVENTORY_ITEM_ID(+)
            And item_cat.cat_ORGANIZATION_ID(+) =
                oe_sys_parameters.value('MASTER_ORGANIZATION_ID', wdd.org_id) -- FIX: was a hardcoded org list
            And wnd.planned_flag = wlk.LOOKUP_CODE(+)
            And wlk.LOOKUP_TYPE = 'DELIVERY_PLANNED_FLAG'
            And oola.ship_from_org_id = mpl.organization_id
            And oola.ship_from_org_id = shipping_orgn.from_organization_id
            And oola.org_id = shipping_orgn.cot_operating_unit
               -----------------
            and wnd.initial_pickup_date >= trunc(sysdate) - 600        -- change 2
            and wnd.initial_pickup_date <  sysdate + 1                 -- change 2
            and msib.inventory_item_id = bidc.cat_inventory_item_id(+)
            and bidc.cat_ORGANIZATION_ID(+) =
                oe_sys_parameters.value('MASTER_ORGANIZATION_ID', wdd.org_id)
            and wnd.attribute5 = xcv.CONTAINER_NUMBER(+)
            and trunc(wnd.creation_date) <= trunc(xcv.CODE_43_DATE(+))
            and wnd.attribute5 = xcb.CONTAINER_NUMBER(+)
            and trunc(wnd.creation_date) <= trunc(xcb.CODE_42_DATE(+))
            and oola.line_type_id = OE_TYPES_LINES.TRANSACTION_TYPE_ID(+)
            and wndd.port_of_destination =
                glb_port_dest.global_sea_ports_code(+)
            and wndd.port_of_discharge =
                glb_port_dis.global_sea_ports_code(+)
            and  oola.subinventory       = msv.secondary_inventory_name (+)
            and  oola.ship_from_org_id   = msv.organization_id (+)
         UNION ALL -- PERF FIX: was UNION (avoids a costly SORT UNIQUE)
         ---------------  BRANCH 2: Awaiting shipping
         select
                CASE
                  WHEN wnd.delivery_id IS NOT NULL AND wdd.lot_number IS NOT NULL THEN 'AWAITING_SHIPPING - Delivery Exists - Lot Exists'
                  WHEN wnd.delivery_id IS NOT NULL AND wdd.lot_number IS NULL     THEN 'AWAITING_SHIPPING - Delivery Exists - NO LOT'
                  WHEN wnd.delivery_id IS NULL     AND wdd.lot_number IS NOT NULL THEN 'AWAITING_SHIPPING - NO Delivery - Lot Exists'
                  ELSE                                                                 'AWAITING_SHIPPING - NO Delivery - NO Lot'
                END grp
               ,
                ac.CUSTOMER_NUMBER,
                ac.CUSTOMER_NAME,
                CASE WHEN wnd.delivery_id IS NOT NULL THEN hzloc.address1 ELSE bill_loc.Address1 END address1,
                CASE WHEN wnd.delivery_id IS NOT NULL THEN hzloc.address2 ELSE bill_loc.Address2 END address2,
                CASE WHEN wnd.delivery_id IS NOT NULL THEN hzloc.city     ELSE bill_loc.CITY     END city,
                CASE WHEN wnd.delivery_id IS NOT NULL THEN hzloc.country  ELSE bill_loc.COUNTRY  END country,
                CASE WHEN wnd.delivery_id IS NOT NULL THEN hzloc.address_lines_phonetic ELSE bill_loc.address_lines_phonetic END address_lines_phonetic,
                ship_su.location ship_to_location,
                wnd.name Delivery,
                wnd.dock_code dock_code,
                wnd.confirm_date confirm_date,
                wnd.initial_pickup_date delivery_date,
                wnd.shipping_marks Main_delivery,
                wnd.status_code delivery_status_code,
                wl.meaning delivery_status,
                wl_released.MEANING Pick_released_status_meaning,
                wnd.entry_number Closing_date,
                to_CHAR(fnd_date.canonical_to_date(wnd.entry_number),
                        'DD/MM/RRRR') canonical_Closing_date,
                wdd.source_header_number Order_number,
                wdd.source_line_number Order_line,
                oola.flow_status_code order_line_status,
                to_number(substr(wdd.source_line_number,
                                 1,
                                 instr(wdd.source_line_number, '.') - 1)) Line_number,
                to_number(substr(wdd.source_line_number,
                                 instr(wdd.source_line_number, '.') + 1)) ship_number,
                oola.ordered_quantity,
                (NVL(CASE WHEN wdd.lot_number IS NOT NULL THEN csmr_l.mr_primary_reservation_qnty
                          ELSE csmr_n.mr_primary_reservation_qnty END, 0)) primary_reservation_quantity,
                oola.cancelled_quantity,
                (nvl(wdd.requested_quantity, 0)) requested_quantity,
                nvl(wdd.cancelled_quantity, 0) requested_cancelled_quantity,
                (nvl(wdd.shipped_quantity, 0)) shipped_quantity,
                wdd.requested_quantity_uom,
                wnd.routing_instructions routing_instructions,
                msib.segment1 Item_code,
                msib.description item_description,
                msib.item_type item_type,
                msib.primary_uom_code item_primary_uom_code,
                msib.unit_weight item_unit_weight,
                msib.weight_uom_code item_weight_uom_code
               ,
                wdd.source_header_type_name source_header_type_name,
                wdd.lot_number              wdd_lot_number,
                mln.grade_code              lot_grade
                ---------------------------------------------------------------
               ,
                CASE WHEN wdd.lot_number IS NOT NULL THEN
                       (inv_convert.inv_um_convert(csmr_l.mr_inventory_item_id,
                                                    csmr_l.mr_reservation_uom_code,
                                                    msib.primary_uom_code) *
                        NVL(csmr_l.mr_primary_reservation_qnty, 0))
                     ELSE
                       (inv_convert.inv_um_convert(csmr_n.mr_inventory_item_id,
                                                    csmr_n.mr_reservation_uom_code,
                                                    msib.primary_uom_code) *
                        NVL(csmr_n.mr_primary_reservation_qnty, 0))
                END primary_reserv_qty_converted,
                (wdd.requested_quantity /
                inv_convert.inv_um_convert(wdd.inventory_item_id,
                                            wdd.src_requested_quantity_uom,
                                            wdd.requested_quantity_uom)) Del_Line_Qty_converted,
                wndd.port_of_destination port_of_destination,
                wndd.port_of_discharge port_of_discharge,
                wndd.seal_number seal_no,
                wndd.container_type container_type,
                wndd.container_name container_no,
                wnd.tp_attribute1 site, --fixed by Valeryk 06102022 cr#74201
                wnd.tp_attribute2 transporter_in_israel, --fixed by Valeryk 06102022 cr#74201
                wndd.csc_project Canada_Project,
                wdl.shipper_date BL_date,
                wnd.additional_shipment_info Vessel_Name,
                wnd.freight_terms_code freight_terms_code,
                wnd.problem_contact_reference delivery_remarks,
                wc.freight_code shipping_company,
                wdd.net_weight Total_Weight,
                wdd.weight_uom_code weight_uom_code,
                mp.organization_code,
                ooha.orig_sys_document_ref,
                oola.CUSTOMER_PRODUCTION_LINE cs_comments,
                wnd.attribute7 delivery_hold,
                msib.hazard_class_id hazard_class_id,
                ph.hazard_class hazard_class_code,
                ph.description hazard_class_description
                ------------------
               ,
                oola.order_quantity_uom,
                wdd.source_code,
                wdd.delivery_detail_id,
                wnd.delivery_id,
                wdd.source_header_id      order_header_id,
                wdd.source_line_id        order_line_id,
                wdd.customer_id,
                wdd.organization_id,
                wdd.released_status,
                wdd.inventory_item_id,
                wdd.source_header_type_id,
                wdd.org_id
               ,
                CASE WHEN wdd.lot_number IS NOT NULL THEN csmr_l.mr_demand_source_line_id
                     ELSE csmr_n.mr_demand_source_line_id END demand_source_line_id,
                mtrh.request_number           mo_number,
                mtrl.line_number              mo_line,
                wdd.creation_date             Del_Line_Create_Date,
                wnd.creation_date             Del_Create_Date,
                hou.name                      oe_operating_unit_name,
                null                          AR_TRX_DATE,
                null                          AR_TRX_NUMBER,
                null                          AR_LINE_NUMBER,
                null                          AR_QUANTITY_INVOICED,
                null                          AR_IS_INTERCO,
                null                          oe_in_interface,
                oola.promise_date,
                oola.explosion_date,
                oola.request_date,
                ooha.cust_po_number,
                ooha.flow_status_code         order_status,
                oola.shipment_priority_code   Israel_request_date,
                ooha.fob_point_code           FOB,
                ot.name                       order_transaction_type
               ,
                wnd.planned_flag delivery_planned_flag_Code,
                wlk.MEANING Delivery_Planned_Flag,
                oola.ship_from_org_id oola_ship_from_org_id,
                mpl.organization_code oola_ship_from_org_code,
                item_cat.Item_category inventory_item_category,
                oola.schedule_ship_date oe_schedule_ship_date,
                oola.schedule_arrival_date oe_schedule_arrival_date,
                bidc.cat_CATEGORY_SET_NAME,
                bidc.CSI_SIZE,
                bidc.CSI_SIZE_DETAILS,
                bidc.CSI_COLOR,
                bidc.CSI_COLOR_DETAILS,
                bidc.CSI_THICK,
                bidc.CSI_THICK_DETAILS,
                bidc.CSI_FINISH,
                bidc.CSI_FINISH_DETAILS,
                bidc.CSI_FAMILY,
                bidc.CSI_FAMILY_DETAILS,
                bidc.CSI_CLASSIFICATION,
                bidc.CSI_CLASSIFICATION_DETAILS,
                xcv.CODE_43_DATE,
                xcb.CODE_42_DATE,
                wnd.attribute5 CONTAINER_NUMBER,
                FND_DATE.canonical_to_date(wnd.tp_attribute5) Seal_Date,
                wnd.tp_attribute6 TShip_Port,
                FND_DATE.canonical_to_date(wnd.tp_attribute7) TShip_ETA,
                FND_DATE.canonical_to_date(wnd.tp_attribute8) TShip_ETD,
                FND_DATE.canonical_to_date(wnd.tp_attribute10) Final_Port_ETA,
                FND_DATE.canonical_to_date(wnd.tp_attribute11) Final_Dest_ETA,
                wnd.tp_attribute12 Status,
                FND_DATE.canonical_to_date(wnd.tp_attribute13) Status_Date,
                FND_DATE.canonical_to_date(wnd.entry_number) CS_Closing_Date,
                ooha.creation_date order_creation_date,
                oola.creation_date order_line_creation_date,
                ooha.booked_date order_booked_date,
                ooha.ordered_date ordered_date,
                oola.shipping_instructions oe_line_shipping_instructions,
                ooha.order_type_id order_type_id,
                oola.line_type_id order_line_type_id,
                oe_types_lines.name order_line_transaction_type,
                oola.unit_list_price oe_unit_list_price,
                oola.unit_selling_price oe_unit_selling_price,
                oola.packing_instructions oe_line_packing_instructions,
                ooha.transactional_curr_code oe_transactional_curr_code,
                oola.source_document_type_id,
                case
                  when oola.source_document_type_id = 10 and not (wnd.delivery_id is null and wdd.lot_number is null) then
                   (select rtrim(REGEXP_REPLACE(LISTAGG(rl.destination_subinventory,
                                                        ';') within
                                                group(order by
                                                      RH.REQUISITION_HEADER_ID),
                                                '([^;]*)(;\1)+($|;)',
                                                '\1\3'),
                                 ';')
                      FROM po_requisition_headers_all rh,
                           po_requisition_lines_all   rl
                     Where 1 = 1
                       And RH.REQUISITION_HEADER_ID = rl.requisition_header_id
                       And rh.requisition_header_id = ooha.source_document_id
                       And rl.requisition_line_id =
                           oola.source_document_line_id)
                  when oola.source_document_type_id = 10 and (wnd.delivery_id is null and wdd.lot_number is null) then
                   (select rtrim(REGEXP_REPLACE(LISTAGG(rl.destination_subinventory,
                                                        ';') within
                                                group(order by
                                                      RH.REQUISITION_HEADER_ID),
                                                '([^;]*)(;\1)+($|;)',
                                                '\1\3'),
                                 ';')
                      FROM po_requisition_headers_all rh,
                           po_requisition_lines_all   rl
                     Where 1 = 1
                       And RH.REQUISITION_HEADER_ID = rl.requisition_header_id
                       And rh.requisition_header_id = ooha.source_document_id)
                END destination_subs,
                case
                  when oola.source_document_type_id = 10 then
                   (select rtrim(REGEXP_REPLACE(LISTAGG(mp2.organization_code,
                                                        ';') within
                                                group(order by
                                                      RH.REQUISITION_HEADER_ID),
                                                '([^;]*)(;\1)+($|;)',
                                                '\1\3'),
                                 ';')
                      FROM po_requisition_headers_all rh,
                           po_requisition_lines_all   rl,
                           mtl_parameters             mp2
                     Where 1 = 1
                       And RH.REQUISITION_HEADER_ID = rl.requisition_header_id
                       And rh.requisition_header_id = ooha.source_document_id
                       And rl.destination_organization_id = mp2.organization_id)
                END destination_orgn,
                glb_port_dest.global_sea_ports_meaning glb_port_dest_meaning,
                glb_port_dest.global_sea_ports_description glb_port_dest_description
               ,
                glb_port_dis.global_sea_ports_meaning glb_port_dis_meaning,
                glb_port_dis.global_sea_ports_description glb_port_dis_description,
                oola_dfv.first_ship_date                        first_ship_date,
                TO_DATE(wnd.TP_ATTRIBUTE5, 'YYYY/MM/DD HH24:MI:SS')   sail_date,  --fixed by Valeryk 06102022 cr#74201
                ship_cas.attribute11                            customs_broker,
                trunc(sysdate) - 600                            From_report_date,   -- change 2
                sysdate                                         To_report_date,     -- change 2
                oola.subinventory                oola_subinventory,
                msv.description                  subinventory_description,
                wdd.gross_weight                 gross_weight,
                -- change 6: cached per delivery_id
                CASE WHEN wnd.delivery_id IS NOT NULL THEN
                       NVL((select xxcs_oem_direct_po_util_pkg.xxoem_actual_forwarder_f(wnd.delivery_id) from dual),
                           ship_cas.attribute11)
                     ELSE
                       ac.attribute6
                END Forwarder,
                wnd.waybill Booking_Number,
                -- change 6: cached per item/org
                (select XXCS_PLN_UTILS.GET_SOURCEING_RULE(0,msib.inventory_item_id,msib.organization_id) from dual) Item_Org_Source,
                CASE WHEN wnd.delivery_id IS NOT NULL THEN wnd.last_update_date ELSE wdd.last_update_date END last_update_date
           from wsh_delivery_details     wdd,
                oe_order_lines_all       oola,
                oe_order_lines_all_dfv   oola_dfv,
                oe_order_headers_all     ooha,
                ar_customers             ac,
                hz_cust_site_uses_all    ship_su,
                hz_cust_acct_sites_all   ship_cas,
                hz_locations             hzloc,
                hz_party_sites           bill_ps,
                hz_locations             bill_loc,
                BI_ITEM_DIME_CAT         bidc,
                wsh_lookups              wl_released,
                wsh_lookups              wl,
                wsh_lookups              wlk,
                wsh_delivery_assignments wda,
                wsh_new_deliveries       wnd,
                mtl_system_items_b       msib,
                po_hazard_classes        ph,
                mtl_lot_numbers          mln,
                wsh_new_deliveries_dfv   wndd,
                global_sea_ports         glb_port_dest,
                global_sea_ports         glb_port_dis,
                wsh_delivery_legs        wdl,
                wsh_carriers             wc,
                CS_RESERVATIONS          csmr_l,
                CS_RESERVATIONS_NL       csmr_n,
                mtl_txn_request_headers  mtrh,
                mtl_txn_request_lines    mtrl,
                mtl_parameters           mp,
                hr_operating_units       hou,
                OE_TRANSACTION_TYPES_TL  ot,
                mtl_parameters           mpl,
                item_cat                 item_cat,
                shipping_orgn            shipping_orgn,
                code_43                  xcv,
                code_42                  xcb,
                OE_TRXT_TYPES_NOORGS_VL  OE_TYPES_LINES,
                mtl_secondary_inventories   msv
          where 1 = 1
            AND OOLA.OPEN_FLAG = 'Y'
            and nvl(oola.cancelled_flag, 'N') = 'N'
            and OOLA.FLOW_STATUS_CODE = ('AWAITING_SHIPPING')
            and oola.header_id = ooha.header_id
            And oola.rowid  = oola_dfv.row_id (+)
            And oola.ship_from_org_id = mpl.organization_id
            And ooha.order_type_id = ot.transaction_type_id
            And ot.language = userenv('LANG')
            and wdd.source_line_id(+) = oola.line_id
            and wdd.delivery_detail_id = wda.delivery_detail_id(+)
            and wda.delivery_id = wnd.delivery_id(+)
            and wdd.released_status = wl_released.lookup_code(+)
            and wl_released.lookup_type(+) = 'PICK_STATUS'
            and wnd.status_code = wl.lookup_code(+)
            and wl.lookup_type(+) = 'DELIVERY_STATUS'
            and wdd.source_code(+) = 'OE'
            and wdd.inventory_item_id = msib.inventory_item_id(+)
            and wdd.organization_id = msib.organization_id(+)
            and wdd.inventory_item_id = mln.inventory_item_id(+)
            and wdd.organization_id = mln.organization_id(+)
            and wdd.lot_number = mln.lot_number(+)
            and msib.hazard_class_id = ph.HAZARD_CLASS_ID(+)
            And wdd.organization_id = mp.organization_id
            and wnd.rowid = wndd.row_id(+)
            and wnd.delivery_id = wdl.delivery_id(+)
            and wnd.carrier_id = wc.carrier_id(+)
            and wdd.move_order_line_id = mtrl.line_id(+)
            and mtrl.header_id = mtrh.header_id(+)
            and wdd.inventory_item_id = csmr_l.mr_inventory_item_id(+)
            and wdd.organization_id = csmr_l.mr_organization_id(+)
            and wdd.source_line_id = csmr_l.mr_demand_source_line_id(+)
            AND WDD.LOT_NUMBER = csmr_l.mr_LOT_NUMBER(+)
            and (CASE WHEN wdd.lot_number IS NULL THEN wdd.inventory_item_id END) = csmr_n.mr_inventory_item_id(+)
            and wdd.organization_id = csmr_n.mr_organization_id(+)
            and wdd.source_line_id = csmr_n.mr_demand_source_line_id(+)
            and ooha.sold_to_org_id = ac.Customer_id
            and wnd.ultimate_dropoff_location_id = hzloc.location_id(+)
            and oola.ship_to_org_id = ship_su.site_use_id(+)
            and SHIP_su.cust_acct_site_id          = ship_cas.cust_acct_site_id (+)
            and ship_cas.party_site_id = bill_ps.party_site_id(+)
            and bill_ps.location_id = bill_loc.location_id(+)
            and oola.org_id = hou.organization_id
               ----------------------------------------------------------------------------------------------------
            And wdd.inventory_item_id = item_cat.cat_INVENTORY_ITEM_ID(+)
            And item_cat.cat_ORGANIZATION_ID(+) =
                oe_sys_parameters.value('MASTER_ORGANIZATION_ID', wdd.org_id) -- FIX: was a hardcoded org list
            And wnd.planned_flag = wlk.LOOKUP_CODE(+)
            And wlk.LOOKUP_TYPE(+) = 'DELIVERY_PLANNED_FLAG'
            And oola.ship_from_org_id = shipping_orgn.from_organization_id
            And oola.org_id = shipping_orgn.cot_operating_unit
            And oola.ship_from_org_id = mpl.organization_id
               -----------------
            and msib.inventory_item_id = bidc.cat_inventory_item_id(+)
            and bidc.cat_ORGANIZATION_ID(+) =
                oe_sys_parameters.value('MASTER_ORGANIZATION_ID', wdd.org_id)
            and wnd.attribute5 = xcv.CONTAINER_NUMBER(+)
            and trunc(wnd.creation_date) <= trunc(xcv.CODE_43_DATE(+))
            and wnd.attribute5 = xcb.CONTAINER_NUMBER(+)
            and trunc(wnd.creation_date) <= trunc(xcb.CODE_42_DATE(+))
            and oola.line_type_id = OE_TYPES_LINES.TRANSACTION_TYPE_ID(+)
            and wndd.port_of_destination =
                glb_port_dest.global_sea_ports_code(+)
            and wndd.port_of_discharge =
                glb_port_dis.global_sea_ports_code(+)
            and  oola.subinventory       = msv.secondary_inventory_name (+)
            and  oola.ship_from_org_id   = msv.organization_id (+)
            and oola.creation_date > TRUNC(ADD_MONTHS(SYSDATE, -24), 'YYYY')
          ) d
       ) x
  ) DLV
;
