/// Difficulty bonuses apply to the selected stage's existing clear rewards.
/// Hard stage files may already have a higher base; keep those authored values.
function level_reward_difficulty(_value) {
    if (!is_real(_value)) return 1;
    return clamp(floor(_value), 0, 3);
}

function level_reward_multiplier(_difficulty) {
    var _multipliers = [1, 1.25, 1.5, 2];
    return _multipliers[level_reward_difficulty(_difficulty)];
}

function level_reward_difficulty_name(_difficulty) {
    var _names = ["美味级", "火山级", "浮空级", "星际级"];
    return _names[level_reward_difficulty(_difficulty)];
}

/// Each resource stack rounds down once. Unlocks are not numeric resource stacks.
function level_reward_amount(_base, _difficulty) {
    return floor(max(0, real(_base)) * level_reward_multiplier(_difficulty));
}
