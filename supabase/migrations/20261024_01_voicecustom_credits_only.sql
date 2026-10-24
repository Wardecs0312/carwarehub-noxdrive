-- Кастомный голос MMVoice: цена только в кредитах (2 кр.), без рублей и долларов (решение Алишера 24.10.2026).
-- Программа с 2.0.38 не показывает «0 ₽ / $0» у цены только в кредитах (models.dart, moneyText).
-- Применять после выпуска 2.0.38, иначе старые версии покажут «0 ₽ / $0».
update price_groups set price_credits = 2, price_rub = 0, price_usd = 0 where code = 'voicecustom';
update services set price_credits = 2 where code = 'voicecustom';
