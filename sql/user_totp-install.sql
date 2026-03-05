-- 2FA TOTP support for XEP-DEVICES
-- Run this against the ejabberd PostgreSQL database

CREATE TABLE IF NOT EXISTS user_totp (
    jid text PRIMARY KEY,
    totp_secret text NOT NULL,    -- base32-encoded TOTP secret
    enabled boolean DEFAULT true,
    created_at bigint NOT NULL DEFAULT (extract(epoch from now())::bigint)
);

-- Example: enable 2FA for a user
-- INSERT INTO user_totp (jid, totp_secret)
-- VALUES ('user@domain.com', 'JBSWY3DPEHPK3PXP');
--
-- The totp_secret should be a base32-encoded random key (20+ bytes).
-- Generate one with: python3 -c "import pyotp; print(pyotp.random_base32())"
