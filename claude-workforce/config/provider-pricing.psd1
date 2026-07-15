@{
    schema_version = 1
    models = @(
        @{
            model = 'deepseek-v4-flash[1m]'
            verified_on = '2026-07-14'
            max_age_days = 14
            source = 'official'
            currency = 'CNY'
            rates = @{
                cache_hit_per_million = '0.02'
                cache_miss_per_million = '1'
                output_per_million = '2'
            }
        }
        @{
            model = 'deepseek-v4-pro[1m]'
            verified_on = '2026-07-14'
            max_age_days = 14
            source = 'official'
            currency = 'CNY'
            rates = @{
                cache_hit_per_million = '0.025'
                cache_miss_per_million = '3'
                output_per_million = '6'
            }
        }
    )
}
