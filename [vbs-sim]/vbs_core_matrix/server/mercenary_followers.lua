-- =====================================================================
-- MATRIX MUHAFIZ/KURYE TAKİPÇİLERİ / server/mercenary_followers.lua (KATMAN 1)
--
-- Fiziksel takipçi ped'lerinin KENDİSİ tamamen client-side'da (client/
-- mercenary_followers.lua) yönetilir (GTA V ped AI'ı server-authoritative
-- DEĞİLDİR, mevcut kodun HİÇBİR yerinde de değildir -- örn. trap house
-- iç mekan ambient ped'leri de client-side). Sunucu yalnızca: (a) F10
-- çağrısının Config.Mercenary.MaxFollowers/SummonCooldownMs disiplinine
-- uyduğunu doğrular, (b) tetiklenen çağrıyı ilgili client'a yansıtır.
-- =====================================================================


Matrix.Mercenary = Matrix.Mercenary or {}


local SummonCooldown  = {} -- [src] = sonraki izinli cagri zamani
local FollowerCount    = {} -- [src] = suanki aktif takipci sayisi


RegisterNetEvent('matrix:server:mercenary:requestSummon', function()
    local src = source
    if not Config.Mercenary.EnablePhysicalFollowers then return end

    local now = Matrix.Now()
    if SummonCooldown[src] and now < SummonCooldown[src] then
        TriggerClientEvent('matrix:client:actionNotify', src, false, 'Takipci cagirma kisa bir sure sonra tekrar kullanilabilir.')
        return
    end

    local current = FollowerCount[src] or 0
    if current >= (Config.Mercenary.MaxFollowers or 2) then
        TriggerClientEvent('matrix:client:actionNotify', src, false, 'Zaten maksimum takipci sayisina ulastiniz.')
        return
    end

    SummonCooldown[src] = now + math.floor((Config.Mercenary.SummonCooldownMs or 5000) / 1000)
    FollowerCount[src]   = current + 1

    TriggerClientEvent('matrix:client:mercenary:summonApproved', src, FollowerCount[src])
end)


RegisterNetEvent('matrix:server:mercenary:reportDismiss', function(remainingCount)
    local src = source
    FollowerCount[src] = math.max(0, tonumber(remainingCount) or 0)
end)


AddEventHandler('playerDropped', function()
    local src = source
    SummonCooldown[src] = nil
    FollowerCount[src]   = nil
end)
