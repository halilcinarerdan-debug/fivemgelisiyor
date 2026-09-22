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
-- -- YALNIZCA elle '/matrix_run_diagnostics deep' ile, İKİ-FAZLI ÇIKIŞ
-- KÖPRÜSÜ'nü GERÇEKTEN bir kullan-at test botuyla uçtan uca kanıtlar,
-- ardından Matrix.RemoveBot ile TAMAMEN geri alır (aşağıda). ASLA otomatik
-- tetiklenmez -- bir GM'in bilerek çalıştırdığı, kısa ve geri alınabilir
-- bir eylemdir.
--
-- SIFIR RNG: her kontrol saf/deterministiktir -- aynı config + aynı DB
-- durumu HER ZAMAN aynı raporu üretir.
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

-- Matrix.Diagnostics.Run: kendi CreateThread'i içinde çalışır (MySQL.*
-- .await çağrıları coroutine bağlamı GEREKTİRİR -- server/bureau.lua
-- LoadLearningCore İLE AYNI disiplin), bu yüzden Run() top-level'dan da
-- güvenle çağrılabilir.
function Matrix.Diagnostics.Run(deep, replyTo)
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
    -- Otomatik acilis: HER ZAMAN hizli katman, ASLA deep (dosya basi
    -- KAPSAM KARARI).
    Matrix.Diagnostics.Run(false, nil)
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