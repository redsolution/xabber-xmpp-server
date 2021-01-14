alter table groupchat_policy drop column valid_from;
alter table groupchat_policy drop column valid_until;
alter table groupchat_policy add column valid_until bigint not null default 0;
alter table groupchats alter COLUMN status set default 'discussion';

