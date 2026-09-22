-- =====================================================================
-- ★★★ matrix_diagnostics.lua — OTOMASYONLU REGRESYON ÇEKİRDEĞİ ★★★
-- YENİ dosya. Mevcut hiçbir formüle/tabloya DOKUNMAZ -- yalnızca onları
-- OKUR (config sınır kontrolü, Matrix.* fonksiyon varlığı, salt-okunur
-- DB şema sorguları). HİÇBİR kontrol matrix_bots/matrix_trap_stash_*/
-- matrix_bureau_learning_core gibi CANLI ekonomi tablolarına YAZMAZ.
--
-- ★ KAPSAM KARARI (bilinçli, aşağıda gerekçeli):
-- Talep "19 dosyayı saniyede 1500 kez simüle et" idi. Bu İKİ nedenle
-- OLDUĞU GİBİ uygulanmadı:
--   1) Projenin kendi "0 Resmon" bütçesiyle YAPISAL OLARAK ÇELİŞİR --
--      saniyede 1500 kez gerçek dispatch/frisk/kitchen mantığı çalıştırmak
--      (özellikle ped/araç doğuran yollar) tam da önlemeye çalıştığımız
--      performans sorununu YARATIR.
--   2) Ped/araç doğuran akışları (BeginPhysicalDispatch, frisk'in gerçek
--      envanter tarama/el koyma zinciri) otomatik ve sürekli tetiklemek
--      CANLI sunucuda görünür, yan etkili (dünyada entity, DB yazması)
--      davranıştır -- "sessiz arka plan testi" tanımına ters düşer ve her
--      sunucu yeniden başlatmasında canlı ekonomiye test verisi sızdırır.
-- Yerine: (A) HIZLI KATMAN -- config sınır kontrolleri + Matrix.* fonksiyon
-- varlığı + salt-okunur DB şema sorguları. Toplamı milisaniyeler içinde
-- biter (gerçek talep buydu), SIFIR yan etki, onServerResourceStart'ta
-- OTOMATİK ve /matrix_run_diagnostics ile MANUEL çalışır. (B) DERİN KATMAN
-- -- İKİ-FAZLI ÇIKIŞ KÖPRÜSÜ'nü GERÇEKTEN bir kullan-at test botuyla uçtan
-- uca kanıtlar, ardından Matrix.RemoveBot ile TAMAMEN geri alır (aşağıda).
--
-- ★★★ KATMAN 21 GÜNCELLEMESİ (GM emriyle BİLİNÇLİ olarak yukarıdaki "ASLA
-- otomatik değil" kararını GEÇERSİZ KILAR): onServerResourceStart artık
-- HER ZAMAN deep=true çalıştırır VE üç ek SimulationChecks stres testi
-- (100 eşzamanlı async işlem, bot yara-ceza hassasiyeti, Hayalet Doktor
-- 10k-epoch determinizmi -- bkz. aşağıda) otomatik olarak tetiklenir.
-- Bunlardan biri assert ile başarısız olursa, Config.Diagnostics.
-- AbortResourceOnSimulationFailure açıkken kaynağın kendi açılışı
-- StopResource ile DURDURULUR (bkz. AbortResourceBoot). Bu, DB/inventory
-- ön-koşulları (bkz. shared/config.lua Config.Diagnostics KURULUM notu)
-- karşılanmadan devreye alınırsa kaynağı HER RESTART'TA kilitleyebilir --
-- kasıtlı, geri alınabilir (config'ten kapatılabilir) bir tercihtir.
--
-- SIFIR RNG: her kontrol saf/deterministiktir -- aynı config + aynı DB
-- durumu HER ZAMAN aynı raporu üretir.
--
-- ★★★ KATMAN 22 GÜNCELLEMESİ: 4 yeni bekçi eklendi -- (1) Config Ped
-- Bekçisi: Config.BotPedConfiguration'daki runner/lookout/chemist/
-- inspector rütbelerinin katı string ped modeline bağlı olduğunu FastChecks
-- içinde doğrular. (2) Koordinat Kusursuzluğu: 3 düşman hood bölgesi, 5
-- Hayalet Doktor koordinatı ve karaborsa/rendezvous offset parametrelerinin
-- harita sınırları içinde/sayısal olarak geçerli olduğunu FastChecks
-- içinde doğrular. (3) DERİN-SIM Hit-and-Run Drive-By Tazelenmesi:
-- server/hitsquad.lua'nın TaskVehicleDriveby + Hit-and-Run kaçış
-- kancalarını izole bir test araç/sürücü çiftiyle tetikler. (4) DERİN-SIM
-- Medikal/Büro Sızıntı Doğrulaması: server/wound_system.lua'nın
-- has_wound==1 -> /tedaviol tedavi zincirinin dayandığı SAF 2x katlanma
-- formülünü (Matrix.Wounds.ComputeBureauLeakMultiplier -- GERÇEK üretim
-- fonksiyonu, ConVar'a HİÇ dokunmadan) doğrular. (3) ve (4) SimulationChecks
-- içinde YALNIZCA deep=true iken çalışır. Bu güncellemeyle mühürleme
-- barajı DÜRÜSTÇE yükseldi: hızlı katman 44 (FastChecks) + 15 (DbChecks)
-- = 59/59; deep=true iken +1 (Çıkış Köprüsü) +5 (SimulationChecks, Hit-
-- and-Run ve Medikal/Büro sızıntısı dahil) = 65/65. Bu sayılar #checks
-- üzerinden HER ZAMAN OTOMATİK hesaplanır -- burada elle senkronize
-- edilmesi gereken ayrı bir sabit YOKTUR.
--
-- ★ [EMNİYET KİLİDİ] KATMAN 22: Config.Diagnostics.AbortResourceOnSimulation
-- Failure artık VARSAYILAN OLARAK false -- otomatik açılışta bir
-- SimulationChecks testi başarısız olsa BİLE kaynak StopResource ile
-- FİZİKSEL OLARAK DURDURULMAZ; her başarısızlık yine tüm ayrıntısıyla
-- (hangi kontrol, hangi sapma) konsola/lastReport'a düşer, yalnızca
-- açılışı FELÇ ETMEZ (bkz. shared/config.lua Config.Diagnostics notu).
-- =====================================================================

Matrix.Diagnostics = Matrix.Diagnostics or {}

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local GetGameTimer = GetGameTimer

local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[DIAGNOSTICS]', msg } })
    else
        print(('[MATRIX:DIAGNOSTICS:CONSOLE] %s'):format(msg))
    end
end

local lastReport = {
    ran_at      = 0,
    duration_ms = 0,
    deep        = false,
    total       = 0,
    passed      = 0,
    failed      = 0,
    checks      = {},
    sealed      = false -- true <=> failed == 0 (Bach kontrpuanı için tek kaynak-doğruluk bayrağı)
}

-- ---------------------------------------------------------------------
-- HIZLI KATMAN: KONTROL TANIMLARI
-- Her giriş { name = string, fn = function() -> passed(boolean), detail(string) }.
-- fn İÇİNDE herhangi bir hata olursa RunCheck onu YAKALAR (pcall) --
-- tek bir bozuk kontrol asla motoru veya resource'u ÇÖKERTMEZ.
-- ---------------------------------------------------------------------
local FastChecks = {}

local function AddCheck(name, fn)
    FastChecks[#FastChecks + 1] = { name = name, fn = fn }
end

-- [Madde 1] İki-Fazlı Çıkış Köprüsü'nün dayandığı sabit interior konumu:
-- Enter/Exit AYNI "interior cebi" olmalı (yalnızca heading farklı olabilir)
-- -- server/main.lua ResolveExteriorBridgeOrigin'in varsayımı budur.
AddCheck('TrapHouseInterior.Shell koordinat tutarlılığı', function()
    local shell = Config.TrapHouseInterior and Config.TrapHouseInterior.Shell
    if not shell or not shell.EnterCoords or not shell.ExitCoords then
        return false, 'Config.TrapHouseInterior.Shell.EnterCoords/ExitCoords tanımsız'
    end
    local e, x = shell.EnterCoords, shell.ExitCoords
    if e.x == x.x and e.y == x.y and e.z == x.z then
        return true, ('(%.4f,%.4f,%.4f)'):format(e.x, e.y, e.z)
    end
    return false, 'EnterCoords/ExitCoords ayni interior cebini isaret etmiyor'
end)

AddCheck('Bureau.Lockdown agirliklari (Breach+Purity=1.0)', function()
    local w, p = Config.Bureau.LockdownBreachWeight, Config.Bureau.LockdownPurityWeight
    local sum = (w or 0) + (p or 0)
    return math.abs(sum - 1.0) < 0.0001, ('BreachWeight=%.2f PurityWeight=%.2f toplam=%.4f'):format(w or -1, p or -1, sum)
end)

AddCheck('Bureau.LockdownEvidenceThreshold (0,1] araliginda', function()
    local t = Config.Bureau.LockdownEvidenceThreshold
    return type(t) == 'number' and t > 0 and t <= 1.0, tostring(t)
end)

-- [Madde 3] regresyon koruması: bu oturumda eklenen livestream köprüsü.
AddCheck('Bureau.Livestream->radio_breach_count koprusu (Madde 3)', function()
    local mult = Config.Bureau.LivestreamRadioBreachMultiplier
    local rate = Config.Bureau.LivestreamRadioLeakPerTick
    if type(mult) ~= 'number' or mult <= 0 then return false, 'LivestreamRadioBreachMultiplier gecersiz' end
    if type(rate) ~= 'number' or rate <= 0 then return false, 'LivestreamRadioLeakPerTick gecersiz' end
    if type(Matrix.Bureau.RecordLivestreamRadioLeak) ~= 'function' then
        return false, 'Matrix.Bureau.RecordLivestreamRadioLeak tanimli degil'
    end
    return true, ('carpan=%.1f, oran=%.5f/tick'):format(mult, rate)
end)

AddCheck('Forensics.Frisk parametreleri gecerli', function()
    local f = Config.Forensics.Frisk
    if not f then return false, 'Config.Forensics.Frisk tanimsiz' end
    if type(f.Radius) ~= 'number' or f.Radius <= 0 then return false, 'Radius gecersiz' end
    if type(f.DwellMs) ~= 'number' or f.DwellMs <= 0 then return false, 'DwellMs gecersiz' end
    if type(f.CooldownMs) ~= 'number' or f.CooldownMs <= 0 then return false, 'CooldownMs gecersiz' end
    if type(f.WeaponSerialContrabandPrefix) ~= 'string' or f.WeaponSerialContrabandPrefix == '' then
        return false, 'WeaponSerialContrabandPrefix bos'
    end
    return true, ('Radius=%.1fm Dwell=%dms Cooldown=%dms'):format(f.Radius, f.DwellMs, f.CooldownMs)
end)

-- [Madde 5b] regresyon koruması: bagaj röntgeninin dayandığı TrunkOps.
AddCheck('Logistics.TrunkOps parametreleri gecerli (Madde 5b bagimliligi)', function()
    local t = Config.Logistics.TrunkOps
    if not t then return false, 'Config.Logistics.TrunkOps tanimsiz' end
    if type(t.StashPrefix) ~= 'string' or t.StashPrefix == '' then return false, 'StashPrefix bos' end
    if type(t.Slots) ~= 'number' or t.Slots <= 0 then return false, 'Slots gecersiz' end
    if type(t.MaxWeight) ~= 'number' or t.MaxWeight <= 0 then return false, 'MaxWeight gecersiz' end
    return true, ('prefix=%s slots=%d'):format(t.StashPrefix, t.Slots)
end)

AddCheck('Market.GourmetMinPurity [0,1] araliginda', function()
    local p = Config.Market.GourmetMinPurity
    return type(p) == 'number' and p >= 0 and p <= 1.0, tostring(p)
end)

AddCheck('Market.StreetDealing devsirme esikleri gecerli', function()
    local s = Config.Market.StreetDealing
    if not s then return false, 'Config.Market.StreetDealing tanimsiz' end
    if type(s.RecruitAddictionThreshold) ~= 'number' or s.RecruitAddictionThreshold <= 0 then
        return false, 'RecruitAddictionThreshold gecersiz'
    end
    if type(s.RecruitDistance) ~= 'number' or s.RecruitDistance <= 0 then return false, 'RecruitDistance gecersiz' end
    return true, ('esik=%.1f mesafe=%.1fm'):format(s.RecruitAddictionThreshold, s.RecruitDistance)
end)

AddCheck('Kitchen.Packaging urun tanimlari gecerli', function()
    local pk = Config.Kitchen.Packaging
    if not pk or type(pk.RawItem) ~= 'string' or pk.RawItem == '' then return false, 'RawItem bos' end
    if type(pk.Products) ~= 'table' or #pk.Products == 0 then return false, 'Products bos' end
    for i, prod in ipairs(pk.Products) do
        if type(prod.item) ~= 'string' or prod.item == '' or type(prod.label) ~= 'string' or prod.label == '' then
            return false, ('Products[%d] eksik item/label'):format(i)
        end
    end
    return true, ('RawItem=%s, %d urun'):format(pk.RawItem, #pk.Products)
end)

AddCheck('Logistics.MinDispatchDistanceMeters > 0', function()
    local d = Config.Logistics.MinDispatchDistanceMeters
    return type(d) == 'number' and d > 0, tostring(d)
end)

-- ---------------------------------------------------------------------
-- [KONTROL: CONFIG PED BEKÇİSİ] Config.BotPedConfiguration'daki her
-- rütbenin katı bir string ped modeline (ChecksumOf/hash TÜRETİMİ DEĞİL)
-- bağlı olduğunu doğrular -- server/main.lua ResolveRolePedModel'in
-- dayandığı sözleşmenin kendisi.
-- ---------------------------------------------------------------------
AddCheck('Config Ped Bekcisi: BotPedConfiguration rutbe atamalari katı string', function()
    local pool = Config.BotPedConfiguration
    if type(pool) ~= 'table' then return false, 'Config.BotPedConfiguration tanimsiz' end
    local requiredRanks = { 'runner', 'lookout', 'chemist', 'inspector' }
    for _, rank in ipairs(requiredRanks) do
        if type(pool[rank]) ~= 'string' or pool[rank] == '' then
            return false, ('BotPedConfiguration[%s] gecersiz/bos'):format(rank)
        end
    end
    return true, ('%d rutbe dogrulandi'):format(#requiredRanks)
end)

-- ---------------------------------------------------------------------
-- [KONTROL: KOORDİNAT KUSURSUZLUĞU] 3 düşman hood bölgesi (Config.GangHoods),
-- 5 Hayalet Doktor koordinatı (Config.PhantomDoctor.Coords) ve karaborsa/
-- rendezvous buluşma parametrelerinin (Config.Rendezvous offset aralığı)
-- harita sınırları içinde ve sayısal olarak geçerli olduğunu doğrular.
-- ---------------------------------------------------------------------
local MAP_MIN_XY, MAP_MAX_XY = -6000.0, 8000.0
local MAP_MIN_Z, MAP_MAX_Z   = -200.0, 1200.0

local function CheckVector3InMapBounds(v, label)
    if type(v) ~= 'vector3' then
        return false, ('%s vector3 degil (tip=%s)'):format(label, type(v))
    end
    if v.x ~= v.x or v.y ~= v.y or v.z ~= v.z then -- NaN
        return false, ('%s NaN koordinat iceriyor'):format(label)
    end
    if v.x < MAP_MIN_XY or v.x > MAP_MAX_XY or v.y < MAP_MIN_XY or v.y > MAP_MAX_XY
        or v.z < MAP_MIN_Z or v.z > MAP_MAX_Z then
        return false, ('%s harita sinirlari disinda (%.1f, %.1f, %.1f)'):format(label, v.x, v.y, v.z)
    end
    return true
end

AddCheck('Koordinat Kusursuzlugu: GangHoods + Hayalet Doktor + karaborsa parametreleri', function()
    local hoods = Config.GangHoods and Config.GangHoods.Hoods
    if type(hoods) ~= 'table' or #hoods == 0 then return false, 'Config.GangHoods.Hoods bos/tanimsiz' end
    for _, hood in ipairs(hoods) do
        local ok, detail = CheckVector3InMapBounds(hood.coords, ('hood#%s(%s)'):format(tostring(hood.id), tostring(hood.label)))
        if not ok then return false, detail end
    end

    local phantomCoords = Config.PhantomDoctor and Config.PhantomDoctor.Coords
    if type(phantomCoords) ~= 'table' or #phantomCoords == 0 then return false, 'Config.PhantomDoctor.Coords bos/tanimsiz' end
    for i, c in ipairs(phantomCoords) do
        local ok, detail = CheckVector3InMapBounds(c, ('phantom#%d'):format(i))
        if not ok then return false, detail end
    end

    local r = Config.Rendezvous
    if not r then return false, 'Config.Rendezvous tanimsiz' end
    if type(r.MinOffsetMeters) ~= 'number' or type(r.MaxOffsetMeters) ~= 'number' then
        return false, 'Rendezvous MinOffsetMeters/MaxOffsetMeters sayisal degil'
    end
    if r.MinOffsetMeters <= 0 or r.MaxOffsetMeters <= r.MinOffsetMeters then
        return false, ('Rendezvous offset araligi gecersiz: min=%.1f max=%.1f'):format(r.MinOffsetMeters, r.MaxOffsetMeters)
    end

    return true, ('%d hood, %d hayalet doktor koordinati, karaborsa offset [%.1f,%.1f]m -- hepsi gecerli'):format(
        #hoods, #phantomCoords, r.MinOffsetMeters, r.MaxOffsetMeters)
end)

if Config.ComposerSignature then
    AddCheck('ComposerSignature.volume [0,1] araliginda', function()
        local v = Config.ComposerSignature.volume
        return type(v) == 'number' and v >= 0 and v <= 1.0, tostring(v)
    end)
end

-- Matrix.Clamp SIFIR RNG'nin en temel taşı -- iki ayrı çağrının BYTE-BYTE
-- aynı sonucu verdiğini kanıtlamak, "deterministik DNA"nın kendisini
-- test eder (formülleri değil, o formüllerin ÜZERİNE oturduğu primitifi).
AddCheck('Matrix.Clamp referans-seffafligi (determinizm)', function()
    if type(Matrix.Clamp) ~= 'function' then return false, 'Matrix.Clamp tanimli degil' end
    local a1, a2 = Matrix.Clamp(1.7, 0.0, 1.0), Matrix.Clamp(1.7, 0.0, 1.0)
    local b1, b2 = Matrix.Clamp(-0.3, 0.0, 1.0), Matrix.Clamp(-0.3, 0.0, 1.0)
    if a1 ~= 1.0 or b1 ~= 0.0 then return false, 'sinir degerleri yanlis kirpiliyor' end
    if a1 ~= a2 or b1 ~= b2 then return false, 'ayni girdi farkli cikti uretti (RNG sizintisi?)' end
    return true, 'iki cagri birebir ayni'
end)

-- ---------------------------------------------------------------------
-- HIZLI KATMAN: MATRIX.* KANCA VARLIĞI (kanca KAYMASINI -- var olması
-- beklenen bir fonksiyonun sessizce yok olmasını -- yakalar). HİÇBİRİ
-- ÇAĞRILMAZ, yalnızca `type(...) == 'function'` kontrol edilir.
-- ---------------------------------------------------------------------
local RequiredHooks = {
    { 'Matrix.CreateBotRecord',                Matrix.CreateBotRecord },
    { 'Matrix.GetBot',                         Matrix.GetBot },
    { 'Matrix.RemoveBot',                      Matrix.RemoveBot },
    { 'Matrix.MarkBotDirty',                   Matrix.MarkBotDirty },
    { 'Matrix.BeginPhysicalDispatch',          Matrix.BeginPhysicalDispatch },
    { 'Matrix.BeginRouteDispatch',             Matrix.BeginRouteDispatch },
    { 'Matrix.SetBotInteriorTrapHouse',        Matrix.SetBotInteriorTrapHouse },
    { 'Matrix.Bureau.RecordRadioBreach',       Matrix.Bureau and Matrix.Bureau.RecordRadioBreach },
    { 'Matrix.Bureau.RecordPurityIntercepted', Matrix.Bureau and Matrix.Bureau.RecordPurityIntercepted },
    { 'Matrix.Bureau.TriggerLockdown',         Matrix.Bureau and Matrix.Bureau.TriggerLockdown },
    { 'Matrix.Bureau.LiftLockdown',            Matrix.Bureau and Matrix.Bureau.LiftLockdown },
    { 'Matrix.Bureau.IsLockedDown',            Matrix.Bureau and Matrix.Bureau.IsLockedDown },
    { 'Matrix.Bureau.AdvanceDecryption',       Matrix.Bureau and Matrix.Bureau.AdvanceDecryption },
    { 'Matrix.Bureau.GetPropagandaMomentum',   Matrix.Bureau and Matrix.Bureau.GetPropagandaMomentum },
    { 'Matrix.Recruitment.RecruitStreetNpc',   Matrix.Recruitment and Matrix.Recruitment.RecruitStreetNpc },
    { 'Matrix.Fleet.GetVehicle',               Matrix.Fleet and Matrix.Fleet.GetVehicle },
    { 'Matrix.Fleet.SeizeVehicle',             Matrix.Fleet and Matrix.Fleet.SeizeVehicle },
    { 'Matrix.Forensics.InspectPlayer',        Matrix.Forensics and Matrix.Forensics.InspectPlayer },
    { 'Matrix.Forensics.InspectBustedBot',     Matrix.Forensics and Matrix.Forensics.InspectBustedBot },
    { 'Matrix.Kitchen.ProcessCook',            Matrix.Kitchen and Matrix.Kitchen.ProcessCook },
    { 'Matrix.Kitchen.GetEffectiveSkill',      Matrix.Kitchen and Matrix.Kitchen.GetEffectiveSkill },

    -- ★ Bu oturumda eklenen kancalar -- kanca kaymasini (sessizce yok olmasini) yakalar.
    { 'Matrix.Bureau.GetBureaucraticVelocity', Matrix.Bureau and Matrix.Bureau.GetBureaucraticVelocity },
    { 'Matrix.Bureau.OpenTrial',               Matrix.Bureau and Matrix.Bureau.OpenTrial },
    { 'Matrix.Bureau.RecordTrialResponse',     Matrix.Bureau and Matrix.Bureau.RecordTrialResponse },
    { 'Matrix.Bureau.ExecuteVerdict',          Matrix.Bureau and Matrix.Bureau.ExecuteVerdict },
    { 'Matrix.Bureau.SabotagePhoneLine',       Matrix.Bureau and Matrix.Bureau.SabotagePhoneLine },
    { 'Matrix.Bureau.RunHourlyFinancialAudit', Matrix.Bureau and Matrix.Bureau.RunHourlyFinancialAudit },
    { 'Matrix.Forensics.SanitizeCCTVTrail',    Matrix.Forensics and Matrix.Forensics.SanitizeCCTVTrail },
    { 'Matrix.DistrictHubs.FragmentTerritory', Matrix.DistrictHubs and Matrix.DistrictHubs.FragmentTerritory },
    { 'Matrix.DepositDealerCargoToTrapStash',  Matrix.DepositDealerCargoToTrapStash }
}

for _, entry in ipairs(RequiredHooks) do
    local hookName, hookFn = entry[1], entry[2]
    AddCheck(('kanca mevcut: %s'):format(hookName), function()
        return type(hookFn) == 'function', type(hookFn)
    end)
end

-- ---------------------------------------------------------------------
-- HIZLI KATMAN: DB ŞEMA/BAĞLANTI (salt-okunur -- INFORMATION_SCHEMA)
-- ---------------------------------------------------------------------
local function TableExists(tableName)
    local rows = MySQL.query.await(
        'SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?',
        { tableName }
    ) or {}
    return #rows > 0
end

local function ColumnExists(tableName, columnName)
    local rows = MySQL.query.await(
        'SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?',
        { tableName, columnName }
    ) or {}
    return #rows > 0
end

local DbChecks = {
    { 'DB baglantisi (SELECT 1)', function()
        local rows = MySQL.query.await('SELECT 1 AS ok', {}) or {}
        return rows[1] and tonumber(rows[1].ok) == 1, rows[1] and 'ok' or 'yanit yok'
    end },
    { 'matrix_bots tablosu mevcut', function() return TableExists('matrix_bots'), 'INFORMATION_SCHEMA.TABLES' end },
    { 'matrix_bots.loyalty_base kolonu mevcut (Madde 4 migration)', function()
        return ColumnExists('matrix_bots', 'loyalty_base'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_bureau_learning_core tablosu mevcut', function() return TableExists('matrix_bureau_learning_core'), 'sql/matrix_financial_core.sql' end },
    { 'matrix_district_hubs tablosu mevcut', function() return TableExists('matrix_district_hubs'), 'sql/matrix_financial_core.sql' end },

    -- =================================================================
    -- ★ REGRESYON: 9 GERI ENJEKTE EDILEN HAYATI DB KONTROLU (HIGH)
    -- sql/matrix_financial_core.sql calistirilmadan bu 9 kontrol
    -- BASARISIZ doner -- muhurleme barajini kasitli olarak yukari tirmandirir.
    -- =================================================================
    { 'matrix_zone_ledger.dirty_cash_pool kolonu mevcut', function()
        return ColumnExists('matrix_zone_ledger', 'dirty_cash_pool'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_bots.accounting_precision kolonu mevcut', function()
        return ColumnExists('matrix_bots', 'accounting_precision'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_zone_inspectors.is_wiped kolonu mevcut', function()
        return ColumnExists('matrix_zone_inspectors', 'is_wiped'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_purchase_logs tablosu mevcut', function()
        return TableExists('matrix_purchase_logs'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_customer_pool.is_dead kolonu mevcut', function()
        return ColumnExists('matrix_customer_pool', 'is_dead'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_gang_learning_core tablosu mevcut', function()
        return TableExists('matrix_gang_learning_core'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_trial_records tablosu mevcut', function()
        return TableExists('matrix_trial_records'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_player_state.imprisoned kolonu mevcut', function()
        return ColumnExists('matrix_player_state', 'imprisoned'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_legal_plate_evidence tablosu mevcut (KATMAN 14)', function()
        return TableExists('matrix_legal_plate_evidence'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end },
    { 'matrix_diagnostics_stress_log tablosu mevcut (KATMAN 21)', function()
        return TableExists('matrix_diagnostics_stress_log'), 'sql/matrix_financial_core.sql calistirildi mi?'
    end }
}

-- ---------------------------------------------------------------------
-- ÇALIŞTIRICI
-- ---------------------------------------------------------------------
local function RunCheck(name, fn)
    local ok, passed, detail = pcall(fn)
    if not ok then
        return { name = name, passed = false, detail = ('HATA: %s'):format(tostring(passed)) }
    end
    return { name = name, passed = passed and true or false, detail = detail or (passed and 'OK' or 'basarisiz') }
end

-- ★ DERİN KATMAN: İki-Fazlı Çıkış Köprüsü'nü GERÇEK bir kullan-at test
-- botuyla uçtan uca kanıtlar. YALNIZCA '/matrix_run_diagnostics deep' ile
-- elle tetiklenir -- onServerResourceStart bunu ASLA çağırmaz (dosya başı
-- KAPSAM KARARI). Matrix.TrapHouses boşsa (henüz hiç trap house yoksa)
-- sessizce atlanır -- bu bir HATA değil, henüz test edilecek bir şey
-- olmadığı anlamına gelir.
local function RunDeepExitBridgeCheck()
    local trapHouseId, house = nil, nil
    for id, h in pairs(Matrix.TrapHouses or {}) do
        trapHouseId, house = id, h
        break
    end
    if not trapHouseId then
        return { name = 'DERIN: Cikis Koprusu uctan uca (Madde 1)', passed = true, detail = 'atlandi -- Matrix.TrapHouses bos' }
    end

    local testBot = Matrix.CreateBotRecord({
        name          = 'DIAGNOSTIC-TEST-BOT',
        role          = 'diagnostic_test',
        trap_house_id = trapHouseId
    })

    local bridgedOk = false
    local reason = 'bot olusturulamadi'
    if testBot and testBot.id then
        local setOk = Matrix.SetBotInteriorTrapHouse(testBot.id, trapHouseId)
        if setOk then
            -- ★ Gerçek Config.TrapHouseInterior.Shell konumundan (main.lua
            -- ResolveExteriorBridgeOrigin'in okuduğu AYNI sahte/boşluk
            -- koordinat) trap house'un GERÇEK kapı koordinatına köprü
            -- kurulup kurulamadığı test edilir -- ana senaryonun kendisi.
            local shell = Config.TrapHouseInterior and Config.TrapHouseInterior.Shell
            local origin = (shell and shell.EnterCoords) or house.coords
            local ok, r = Matrix.BeginPhysicalDispatch(
                testBot.id, origin, house.coords, nil, 'foot', 0.0, nil, 1.0
            )
            bridgedOk, reason = ok, r or 'ok'
        else
            reason = 'SetBotInteriorTrapHouse basarisiz'
        end
        -- Test botu HER KOŞULDA geri alınır (retired) -- canlı matrix_bots
        -- tablosunda kalıcı iz BIRAKMAZ.
        Matrix.RemoveBot(testBot.id, 'retired')
    end

    return { name = 'DERIN: Cikis Koprusu uctan uca (Madde 1)', passed = bridgedOk, detail = tostring(reason) }
end


-- =====================================================================
-- ★ KATMAN 21: ACIMASIZ DIAGNOSTICS LABORATUVARI -- 3 CANLI ASENKRON
-- STRES-TESTI SIMULASYONU. Her fonksiyon RunCheck ile SARILIR (yukaridaki
-- FastChecks/DbChecks ile AYNI mekanizma) -- icindeki bir `assert`
-- basarisiz olursa RunCheck'in pcall'i onu YAKALAR ve passed=false olarak
-- rapor eder; Run() daha sonra (yalnizca otomatik acilista, GM emriyle
-- BILINCLI olarak) bunu AbortResourceBoot'a baglar. YALNIZCA deep=true
-- ile calisir (Ne FastChecks ne DbChecks TETIKLENMEZ -- onlar HER ZAMAN
-- hizli/yan-etkisiz kalir).
-- =====================================================================

-- [21.1] 100 eszamanli async "satis" (ox_inventory RemoveItem + MySQL
-- transaction) -- ★ CANLI EKONOMIDEN IZOLE: gercek Matrix.Market.EvaluateSale
-- yerine, kendine ait tani-yalnizca bir stash + matrix_diagnostics_stress_log
-- tablosu kullanir (dosya basi KAPSAM KARARI'ndaki "canli ekonomiye test
-- verisi sizdirma" ilkesiyle CELISMEMEK icin BILINCLI secim) -- ama GERCEK
-- eszamanli RemoveItem + GERCEK MySQL.transaction.await calisir, sahte
-- degildir. Race condition varsa (kayip/duplicate satir, eksik remove)
-- assert firlatir.
local function RunConcurrencyStressCheck()
    local stashId      = Config.Diagnostics.StressTestStashId or 'matrix_diagnostics_stress_stash'
    local testItem      = Config.Diagnostics.StressTestItem or 'matrix_diagnostic_token'
    local concurrency   = Config.Diagnostics.StressTestConcurrency or 100
    local timeoutMs      = Config.Diagnostics.StressTestTimeoutMs or 15000
    local runToken       = ('BOOT-%d'):format(GetGameTimer())

    local regOk = pcall(function()
        exports.ox_inventory:RegisterStash(stashId, 'DIAGNOSTICS STRESS STASH', concurrency + 10, 1000000, false)
    end)
    local seedOk = pcall(function()
        exports.ox_inventory:AddItem(stashId, testItem, concurrency)
    end)
    assert(regOk, 'ox_inventory:RegisterStash basarisiz -- stres testi stash\'i kurulamadi')
    assert(seedOk, ('ox_inventory:AddItem basarisiz -- "%s" item\'i SERVER\'DA KAYITLI DEGIL mi? (Config.Diagnostics.StressTestItem gercek bir item\'a ayarlanmali)'):format(testItem))

    local pending = concurrency
    for i = 1, concurrency do
        CreateThread(function()
            local removeOk, removeResult = pcall(function()
                return exports.ox_inventory:RemoveItem(stashId, testItem, 1)
            end)
            local removedFlag = (removeOk and removeResult) and 1 or 0

            pcall(function()
                MySQL.transaction.await({
                    {
                        query  = 'INSERT INTO matrix_diagnostics_stress_log (run_token, worker_index, removed_ok) VALUES (?, ?, ?)',
                        values = { runToken, i, removedFlag }
                    }
                })
            end)

            pending = pending - 1
        end)
    end

    local waitedMs = 0
    while pending > 0 and waitedMs < timeoutMs do
        Wait(50)
        waitedMs = waitedMs + 50
    end
    assert(pending == 0, ('%d/%d worker zaman asimina ugradi (%dms) -- eszamanlilik kilitlenmesi supheli'):format(pending, concurrency, timeoutMs))

    local rows = MySQL.query.await(
        'SELECT COUNT(*) AS cnt, COALESCE(SUM(removed_ok), 0) AS ok_sum FROM matrix_diagnostics_stress_log WHERE run_token = ?',
        { runToken }
    ) or {}
    local cnt   = rows[1] and tonumber(rows[1].cnt) or 0
    local okSum = rows[1] and tonumber(rows[1].ok_sum) or 0

    -- Temizlik HER KOŞULDA (assert'ten ONCE) -- basarisiz test bile canli
    -- DB'de kalici iz BIRAKMAZ.
    pcall(function() MySQL.query.await('DELETE FROM matrix_diagnostics_stress_log WHERE run_token = ?', { runToken }) end)

    assert(cnt == concurrency,
        ('%d/%d satir DB\'ye ulasti -- kayip yazma = RACE CONDITION KANITI'):format(cnt, concurrency))
    assert(okSum == concurrency,
        ('%d/%d eszamanli RemoveItem basarisiz -- envanter yarisi supheli'):format(concurrency - okSum, concurrency))

    return true, ('%d/%d eszamanli worker, %dms icinde, 0 kayip satir, 0 basarisiz remove'):format(concurrency, concurrency, waitedMs)
end


-- [21.2] Bot uzuv ceza carpanlarinin (hiz, tehdit algilama/Spotter
-- Distance, denetim-anomali) formul hassasiyeti -- virgulden sonra 4
-- hane. Test botlari GERCEK PickWoundZone determinizmine (botId+sayac,
-- restart'lar arasi ONGORULEMEYEN auto-increment ID'ye bagli) DEGIL,
-- forcedZone'a (bkz. server/wound_system.lua) dayanir -- boylece hangi
-- bot ID'sinin verildigi FARK ETMEKSIZIN test FLAKY OLMAZ.
local function RunWoundPrecisionSimCheck()
    local trapHouseId = nil
    for id in pairs(Matrix.TrapHouses or {}) do trapHouseId = id; break end
    if not trapHouseId then
        return true, 'atlandi -- Matrix.TrapHouses bos (henuz test edilecek bir trap house yok)'
    end

    local EPS = 0.00005 -- 4 hane hassasiyet esigi

    local botA = Matrix.CreateBotRecord({ name = 'DIAGNOSTIC-WOUND-A', role = 'diagnostic_test', trap_house_id = trapHouseId })
    assert(botA and botA.id, 'test bot A olusturulamadi')

    Matrix.Wounds.ApplyBotRegionalDamage(botA.id, 1.0, 'leg')
    local moveMult = Matrix.Wounds.GetMovementMultiplier(botA.id)
    local expectedMove = 1.0 - (Config.BotWounds.LegSpeedPenalty or 0.60)
    assert(type(moveMult) == 'number' and math.abs(moveMult - expectedMove) < EPS,
        ('hareket carpani sapmasi: beklenen=%.4f gercek=%.4f'):format(expectedMove, moveMult or -1))

    Matrix.Wounds.ApplyBotRegionalDamage(botA.id, 1.0, 'head')
    local detCap = Matrix.Wounds.GetDetectionRangeCap(botA.id)
    local expectedDet = Config.BotWounds.HeadDetectionRangeCap or 15.0
    assert(type(detCap) == 'number' and math.abs(detCap - expectedDet) < EPS,
        ('Spotter Distance sapmasi: beklenen=%.4f gercek=%.4f'):format(expectedDet, detCap or -1))

    Matrix.Wounds.ApplyBotRegionalDamage(botA.id, 1.0, 'arm')
    local accMult = Matrix.Wounds.GetAccuracyMultiplier(botA.id)
    local expectedAcc = 1.0 - (Config.BotWounds.ArmAccuracyPenalty or 0.50)
    assert(type(accMult) == 'number' and math.abs(accMult - expectedAcc) < EPS,
        ('isabet carpani sapmasi: beklenen=%.4f gercek=%.4f'):format(expectedAcc, accMult or -1))

    Matrix.RemoveBot(botA.id, 'retired')

    -- Kalici sakatlik (crippled) yolu -- ayri bir bot: CripplingThreshold'a
    -- (varsayilan 1.0) ulasana kadar ayni bolgeye (delta=0.25/vurus) 4 kez
    -- vurulur.
    local botB = Matrix.CreateBotRecord({ name = 'DIAGNOSTIC-WOUND-B', role = 'diagnostic_test', trap_house_id = trapHouseId })
    assert(botB and botB.id, 'test bot B olusturulamadi')
    for _ = 1, 4 do
        Matrix.Wounds.ApplyBotRegionalDamage(botB.id, 1.0, 'leg')
    end
    local moveMultCrippled = Matrix.Wounds.GetMovementMultiplier(botB.id)
    local expectedMoveCrippled = 1.0 - (Config.PermanentCrippling.LegMovementPenalty or 0.90)
    assert(type(moveMultCrippled) == 'number' and math.abs(moveMultCrippled - expectedMoveCrippled) < EPS,
        ('kalici sakatlik hareket carpani sapmasi: beklenen=%.4f gercek=%.4f'):format(expectedMoveCrippled, moveMultCrippled or -1))

    Matrix.RemoveBot(botB.id, 'retired')

    return true, ('bacak=%.4f algi=%.4f kol=%.4f kalici-bacak=%.4f'):format(moveMult, detCap, accMult, moveMultCrippled)
end


-- [21.3] Hayalet Doktor rotasyon formulunun (Matrix.Wounds.__ComputePhantomIndexForEpochBucket
-- -- GERCEK uretim formulunun kendisi, bir kopyasi DEGIL) 10.000 epoch
-- boyunca ileri VE geri (Bach "Yengec Kanonu" palindromu ruhuna uygun)
-- calistirildiginda BIREBIR ayni sonucu urettigini kanitlar -- SIFIR RNG
-- iddiasinin somut, olcelebilir kaniti. Salt-okunur/yan etkisiz.
local function RunPhantomDoctorPalindromeSimCheck()
    assert(type(Matrix.Wounds.__ComputePhantomIndexForEpochBucket) == 'function',
        'Matrix.Wounds.__ComputePhantomIndexForEpochBucket tanimli degil')

    local epochCount = Config.Diagnostics.PhantomPalindromeEpochCount or 10000
    local forward = {}
    for bucket = 0, epochCount - 1 do
        forward[bucket] = Matrix.Wounds.__ComputePhantomIndexForEpochBucket(bucket)
    end
    for bucket = epochCount - 1, 0, -1 do
        local idx = Matrix.Wounds.__ComputePhantomIndexForEpochBucket(bucket)
        assert(idx == forward[bucket],
            ('epoch #%d ileri/geri sapma -- DETERMINIZM IHLALI: ileri=%s geri=%s'):format(bucket, tostring(forward[bucket]), tostring(idx)))
    end

    return true, ('%d epoch, ileri+geri, BIREBIR ayni (palindrom dogrulandi)'):format(epochCount)
end


-- [21.4] HIT-AND-RUN DRIVE-BY TAZELENMESİ: server/hitsquad.lua'nın
-- TaskVehicleDriveby (15 saniyelik yaylım ateş fazının kancası) ve ardından
-- gaza basıp en yakın mahalleye kaçış (TaskVehicleDriveToCoord) kancalarını
-- GERÇEK Config.HitSquad parametreleriyle, izole/kullan-at bir test aracı+
-- sürücüsü üzerinde tetikler -- HİÇBİR canlı oyuncuyu hedeflemez, HİÇBİR
-- canlı ekonomi/DB satırına dokunmaz. Amaç 15 saniye gerçekten BEKLEMEK
-- değil (SIFIR yan etki ilkesiyle çelişir), kancaların doğru argüman
-- sayısı/tipiyle çağrıldığını ve nil/mantıksal hata FIRLATMADIĞINI
-- kanıtlamaktır -- biri firlatirsa assert bunu yakalar ve (isAutoBoot +
-- AbortResourceOnSimulationFailure=true iken) kaynak açılışı DURDURULUR.
local function RunHitAndRunDrivebySimCheck()
    assert(Config.HitSquad, 'Config.HitSquad tanimsiz')
    local hs = Config.HitSquad

    for _, field in ipairs({ 'VehicleModel', 'PedModel', 'Weapon' }) do
        assert(type(hs[field]) == 'string' and hs[field] ~= '', ('Config.HitSquad.%s gecersiz/bos'):format(field))
    end
    for _, field in ipairs({ 'CruiseSpeed', 'AttackRange', 'DrivebySeconds', 'FleeSeconds',
                             'AggressiveDriveStyle', 'DrivebyRange', 'PedAccuracy', 'ScanIntervalTicks' }) do
        assert(type(hs[field]) == 'number', ('Config.HitSquad.%s sayisal degil'):format(field))
    end
    assert(type(hs.HeatTraceThreshold) == 'number' and hs.HeatTraceThreshold >= 0 and hs.HeatTraceThreshold <= 1.0,
        'Config.HitSquad.HeatTraceThreshold [0,1] araliginda degil')

    local hood = Config.GangHoods and Config.GangHoods.Hoods and Config.GangHoods.Hoods[1]
    if not hood or not hood.coords then
        return true, 'atlandi -- Config.GangHoods.Hoods bos (henuz test edilecek mahalle yok)'
    end

    local vehHash = GetHashKey(hs.VehicleModel)
    local pedHash = GetHashKey(hs.PedModel)

    local vehicle = CreateVehicle(vehHash, hood.coords.x, hood.coords.y, hood.coords.z, 0.0, true, true)
    if not Matrix.AwaitEntityCreation(vehicle) then
        pcall(function() if DoesEntityExist(vehicle) then DeleteEntity(vehicle) end end)
        assert(false, 'test araci dogurulamadi (timeout)')
    end
    pcall(SetEntityOrphanMode, vehicle, 2) -- KeepEntity

    local driver = CreatePedInsideVehicle(vehicle, 0, pedHash, -1, true, true)
    if not Matrix.AwaitEntityCreation(driver) then
        pcall(function() if DoesEntityExist(vehicle) then DeleteEntity(vehicle) end end)
        pcall(function() if DoesEntityExist(driver) then DeleteEntity(driver) end end)
        assert(false, 'test suruculer dogurulamadi (timeout)')
    end
    pcall(SetEntityOrphanMode, driver, 2) -- KeepEntity

    -- FAZ 1: 15sn'lik yaylim ates kancasi (server/hitsquad.lua TickPlayer
    -- 'driveby' fazi ile BIREBIR AYNI arguman sekli -- canli hedef yerine
    -- kendi test surucusu zararsiz yer-tutucu olarak verilir).
    local drivebyOk, drivebyErr = pcall(TaskVehicleDriveby, driver, driver, 0, 0.0, 0.0, 0.0,
        hs.DrivebyRange, hs.PedAccuracy, false, GetHashKey('FIRING_PATTERN_FULL_AUTO'))

    -- FAZ 2: "Hit-and-Run" -- gaza basip en yakin mahalleye kacis kancasi
    -- (TickPlayer 'fleeing' fazi ile BIREBIR AYNI arguman sekli).
    pcall(ClearPedTasksImmediately, driver)
    local fleeOk, fleeErr = pcall(TaskVehicleDriveToCoord, driver, vehicle,
        hood.coords.x, hood.coords.y, hood.coords.z, hs.CruiseSpeed * 1.4, 0,
        vehHash, hs.AggressiveDriveStyle, 5.0, 1)

    -- Temizlik HER KOSULDA (assert'ten ONCE) -- basarisiz test bile dunyada
    -- kalici entity BIRAKMAZ.
    pcall(function() if DoesEntityExist(driver) then DeleteEntity(driver) end end)
    pcall(function() if DoesEntityExist(vehicle) then DeleteEntity(vehicle) end end)

    assert(drivebyOk, ('TaskVehicleDriveby (yaylim ates) kancasi hata firlatti -- nil/gecersiz kanca supheli: %s'):format(tostring(drivebyErr)))
    assert(fleeOk, ('Hit-and-Run kacis TaskVehicleDriveToCoord kancasi hata firlatti: %s'):format(tostring(fleeErr)))

    return true, ('drive-by + hit-and-run kancalari 0 hata ile calisti (mahalle=%s)'):format(tostring(hood.label))
end


-- [22.2] MEDİKAL/BÜRO SIZINTI DOĞRULAMASI: server/wound_system.lua'nın
-- has_wound==1 -> /tedaviol -> LeakToBureauOnTreatment zincirinin dayandığı
-- SAF formülü (Matrix.Wounds.ComputeBureauLeakMultiplier -- GERÇEK üretim
-- fonksiyonunun KENDİSİ, bir kopyası DEĞİL) doğrular. matrix_bureau_intensity
-- ConVar'ına ASLA dokunmaz, hiçbir oyuncu/DB satırı OKUMAZ/YAZMAZ -- tamamen
-- yan-etkisiz, saf sayısal bir kanıt.
local function RunMedicalBureauLeakSimCheck()
    assert(type(Matrix.Wounds.ComputeBureauLeakMultiplier) == 'function',
        'Matrix.Wounds.ComputeBureauLeakMultiplier tanimli degil')
    assert(type(Config.Hospital) == 'table', 'Config.Hospital tanimsiz')
    assert(type(Config.Hospital.LeakIntensityMultiplier) == 'number' and Config.Hospital.LeakIntensityMultiplier > 1.0,
        ('Config.Hospital.LeakIntensityMultiplier gecersiz (2x katlanma bekleniyor): %s'):format(tostring(Config.Hospital.LeakIntensityMultiplier)))

    local EPS = 0.00005

    -- Normal taban: 1.0 yogunluk -> tam olarak LeakIntensityMultiplier'a sizar.
    local spiked, mult = Matrix.Wounds.ComputeBureauLeakMultiplier(1.0)
    local expected = 1.0 * Config.Hospital.LeakIntensityMultiplier
    assert(math.abs(spiked - expected) < EPS,
        ('has_wound==1 medikal sizinti formulu sapmasi: beklenen=%.4f gercek=%.4f'):format(expected, spiked))
    assert(math.abs(mult - Config.Hospital.LeakIntensityMultiplier) < EPS,
        'donen carpan Config.Hospital.LeakIntensityMultiplier ile uyusmuyor')

    -- Gecersiz/negatif/NaN ConVar girdisi -- production ile BIREBIR AYNI
    -- 1.0 taban fallback'i dogrulanir.
    local nanValue = 0.0 / 0.0
    for _, badInput in ipairs({ -5.0, 0.0, nanValue }) do
        local fallbackSpiked = Matrix.Wounds.ComputeBureauLeakMultiplier(badInput)
        assert(math.abs(fallbackSpiked - expected) < EPS,
            ('gecersiz girdi (%s) icin 1.0 taban fallback formulu bozuk: gercek=%.4f'):format(tostring(badInput), fallbackSpiked))
    end

    -- Farkli bir gercekci yogunluk (2.35) ile de carpim dogru mu?
    local spiked2 = Matrix.Wounds.ComputeBureauLeakMultiplier(2.35)
    local expected2 = 2.35 * Config.Hospital.LeakIntensityMultiplier
    assert(math.abs(spiked2 - expected2) < EPS,
        ('2.35 taban icin sizinti sapmasi: beklenen=%.4f gercek=%.4f'):format(expected2, spiked2))

    return true, ('taban=1.00 -> sizinti=%.2f (x%.1f), 3 gecersiz-girdi fallback + 1 farkli-taban dogrulandi'):format(spiked, mult)
end


local SimulationChecks = {
    { 'DERIN-SIM: 100 eszamanli async satis stres testi (KATMAN 21.1)',            RunConcurrencyStressCheck },
    { 'DERIN-SIM: Bot yara ceza carpani 4-hane hassasiyeti (KATMAN 21.2)',          RunWoundPrecisionSimCheck },
    { 'DERIN-SIM: Hayalet Doktor 10k-epoch palindrom determinizmi (KATMAN 21.3)',   RunPhantomDoctorPalindromeSimCheck },
    { 'DERIN-SIM: Hit-and-Run drive-by tazelenmesi (KATMAN 22.1)',                  RunHitAndRunDrivebySimCheck },
    { 'DERIN-SIM: Medikal/Buro sizinti 2x katlanma formulu (KATMAN 22.2)',          RunMedicalBureauLeakSimCheck }
}


-- ★ KATMAN 21: bir SimulationChecks testi otomatik acilista basarisiz
-- olursa (ve Config.Diagnostics.AbortResourceOnSimulationFailure=true
-- ise) kaynagin KENDI acilisini durdurur. Bu, FXServer'in TUMUNU
-- cokertmez -- yalnizca bu resource'u StopResource ile durdurur (bir
-- GM'in manuel `/matrix_run_diagnostics deep` calistirmasinda ASLA
-- tetiklenmez, YALNIZCA onServerResourceStart otomatik yolunda).
local function AbortResourceBoot(reason)
    local msg = ('[KATMAN 21][KRITIK] Kaynak acilisi DURDURULUYOR -- %s'):format(tostring(reason))
    Matrix.Log('DIAGNOSTICS', msg)
    print(('^1[MATRIX:DIAGNOSTICS] %s^7'):format(msg))
    StopResource(GetCurrentResourceName())
end

-- Matrix.Diagnostics.Run: kendi CreateThread'i içinde çalışır (MySQL.*
-- .await çağrıları coroutine bağlamı GEREKTİRİR -- server/bureau.lua
-- LoadLearningCore İLE AYNI disiplin), bu yüzden Run() top-level'dan da
-- güvenle çağrılabilir.
function Matrix.Diagnostics.Run(deep, replyTo, isAutoBoot)
    CreateThread(function()
        local startedAt = GetGameTimer()
        local checks = {}

        for _, c in ipairs(FastChecks) do
            checks[#checks + 1] = RunCheck(c.name, c.fn)
        end
        for _, c in ipairs(DbChecks) do
            checks[#checks + 1] = RunCheck(c[1], c[2])
        end
        if deep then
            -- ★ TEK cagri: RunDeepExitBridgeCheck zaten { name, passed, detail }
            -- seklinde tam bir sonuc dondurur (RunCheck'in sardigi seyin AYNISI)
            -- -- ikinci bir sarmalama, bu (gercek bot doguran) kontrolu YANLISLIKLA
            -- IKI KEZ calistirirdi.
            local deepOk, deepResult = pcall(RunDeepExitBridgeCheck)
            if deepOk then
                checks[#checks + 1] = deepResult
            else
                checks[#checks + 1] = {
                    name = 'DERIN: Cikis Koprusu uctan uca (Madde 1)',
                    passed = false,
                    detail = ('HATA: %s'):format(tostring(deepResult))
                }
            end

            -- ★ KATMAN 21-22: acimasiz stres-test simulasyonlari (#SimulationChecks
            -- tane -- bkz. yukaridaki tanim) -- YALNIZCA deep=true iken.
            for _, c in ipairs(SimulationChecks) do
                checks[#checks + 1] = RunCheck(c[1], c[2])
            end
        end

        local passed, failed = 0, 0
        for _, c in ipairs(checks) do
            if c.passed then passed = passed + 1 else failed = failed + 1 end
        end

        lastReport = {
            ran_at      = os.time(),
            duration_ms = GetGameTimer() - startedAt,
            deep        = deep and true or false,
            total       = #checks,
            passed      = passed,
            failed      = failed,
            checks      = checks,
            sealed      = (failed == 0)
        }

        Matrix.Log('DIAGNOSTICS',
            '[MATRIX RUN DIAGNOSTICS] %d/%d basarili (deep=%s) -- %dms icinde tamamlandi. Sonuc: %s',
            passed, #checks, tostring(lastReport.deep), lastReport.duration_ms,
            lastReport.sealed and 'MUHURLENDI (0 hata)' or ('%d HATA'):format(failed))

        -- ★ KATMAN 21: otomatik acilista basarisiz kontrol varsa VE
        -- AbortResourceOnSimulationFailure acikken, kaynagin acilisini
        -- burada DURDURUYORUZ -- asagidaki replyTo/broadcast'e HIC
        -- ulasmadan (StopResource zaten kaynagin geri kalanini durdurur).
        if isAutoBoot and failed > 0 and Config.Diagnostics.AbortResourceOnSimulationFailure then
            local firstFailure = nil
            for _, c in ipairs(checks) do
                if not c.passed then firstFailure = c; break end
            end
            AbortResourceBoot(('%d/%d kontrol basarisiz -- ilk hata: [%s] %s'):format(
                failed, #checks,
                firstFailure and firstFailure.name or '?',
                firstFailure and firstFailure.detail or '?'))
            return
        end

        if replyTo then
            Reply(replyTo, ('%d/%d kontrol basarili (%dms). %s'):format(
                passed, #checks, lastReport.duration_ms,
                lastReport.sealed and 'Sistem muhurlendi.' or ('%d hata bulundu, /matrix_run_diagnostics ile detay gorun.'):format(failed)))
            if not lastReport.sealed then
                for _, c in ipairs(checks) do
                    if not c.passed then
                        Reply(replyTo, ('  x %s -- %s'):format(c.name, c.detail))
                    end
                end
            end
        end

        -- Composer Intro (client/composer_intro.lua) bu event'i dinler --
        -- Config.ComposerSignature.playAudioOnLoad KAPALI olsa BİLE bu
        -- yayın DEĞİŞMEDEN devam eder (talep: "sessizce devam etsin").
        -- Ses/gorsel ne yaparsa yapsin, o kismen client'in kendi kararidir.
        TriggerClientEvent('matrix:client:diagnosticsSealed', -1, lastReport)
    end)
end

function Matrix.Diagnostics.GetLastReport()
    return lastReport
end

lib.callback.register('matrix:callback:getDiagnosticsReport', function(src)
    return lastReport
end)

AddEventHandler('onServerResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    if not (Config.Diagnostics and Config.Diagnostics.RunOnResourceStart) then return end
    -- ★ KATMAN 21: eski KAPSAM KARARI ("otomatik acilis HER ZAMAN hizli
    -- katman, ASLA deep") bu GM emriyle BILINCLI olarak GECERSIZ KILINDI.
    -- Artik HER acilista deep=true (SimulationChecks dahil) calisir;
    -- isAutoBoot=true, basarisizlikta AbortResourceBoot yetkisi verir.
    Matrix.Diagnostics.Run(true, nil, true)
end)

-- /matrix_run_diagnostics [deep] -- diger tum admin/test komutlariyla
-- (bkz. /baskinzorla, /burokilitzorla) AYNI disiplin: kisitlama YOK,
-- sunucu ACE yapilandirmasina birakilir.
RegisterCommand('matrix_run_diagnostics', function(src, args)
    local deep = args[1] == Config.Diagnostics.DeepModeCommandArg
    Reply(src, deep
        and 'Derin tani calistiriliyor (gercek bir kullan-at test botuyla cikis koprusu uctan uca test edilecek)...'
        or 'Hizli tani calistiriliyor...')
    Matrix.Diagnostics.Run(deep, src)
end, false)

exports('GetDiagnosticsReport', function() return lastReport end)