-- =============================================================================
-- Entre Nous — 0004_seed_questions.sql
-- Catalogue initial (§5). Rédaction respectueuse, sans contenu coercitif,
-- sans demande de photo intime, sans menace ni humiliation (§5).
-- Les codes sont stables : une question ne change jamais d'identifiant (§8.1).
-- =============================================================================

insert into public.questions (code, category, body) values

-- Brise-glace
('bg-001', 'brise_glace', 'Quel est le meilleur compliment qu''on t''ait fait ?'),
('bg-002', 'brise_glace', 'Si tu pouvais prendre un café avec n''importe qui, qui choisirais-tu et pourquoi ?'),
('bg-003', 'brise_glace', 'Quelle est la première chose qui t''a donné envie d''échanger avec moi ?'),
('bg-004', 'brise_glace', 'Quel souvenir d''enfance te fait sourire instantanément ?'),
('bg-005', 'brise_glace', 'Quelle chanson te met toujours de bonne humeur ?'),
('bg-006', 'brise_glace', 'Quel est ton plaisir simple du quotidien ?'),
('bg-007', 'brise_glace', 'Si ta journée pouvait recommencer, que changerais-tu ?'),
('bg-008', 'brise_glace', 'Qu''est-ce qui te fait rire même quand tu n''as pas envie de rire ?'),

-- Personnalité et habitudes
('ph-001', 'personnalite', 'Te décrirais-tu plutôt comme quelqu''un de spontané ou de réfléchi ?'),
('ph-002', 'personnalite', 'Comment se passe une journée parfaite pour toi, du réveil au coucher ?'),
('ph-003', 'personnalite', 'Quelle habitude aimerais-tu avoir et quelle habitude voudrais-tu perdre ?'),
('ph-004', 'personnalite', 'Quand tu es stressé, qu''est-ce qui t''aide le plus ?'),
('ph-005', 'personnalite', 'Préfères-tu être seul pour recharger ou entouré de monde ?'),
('ph-006', 'personnalite', 'Quelle est ta plus grande qualité, selon toi ?'),
('ph-007', 'personnalite', 'Sur quel sujet as-tu des convictions très fortes ?'),
('ph-008', 'personnalite', 'Qu''est-ce qui te met en colère chez les autres, mais que tu t''autorises parfois ?'),

-- Amour et séduction
('as-001', 'amour', 'Qu''est-ce qui te fait te sentir réellement aimé ?'),
('as-002', 'amour', 'Décris ce que tu trouves séduisant chez quelqu''un.'),
('as-003', 'amour', 'Quel est ton « langage de l''amour » : paroles, gestes, temps, cadeaux ou contact ?'),
('as-004', 'amour', 'Quelle est la chose la plus romantique qu''on ait faite pour toi, ou que tu aies faite ?'),
('as-005', 'amour', 'Qu''est-ce qui te fait te sentir en sécurité dans une relation ?'),
('as-006', 'amour', 'Quelles attentions du quotidien comptent le plus pour toi ?'),
('as-007', 'amour', 'Sur quoi as-tu besoin d''être rassuré(e) ?'),
('as-008', 'amour', 'Quel moment simple aimerais-tu partager plus souvent avec moi ?'),

-- Secrets et confidences
('sc-001', 'secrets', 'Quel rêve n''as-tu jamais osé dire à voix haute ?'),
('sc-002', 'secrets', 'Quelle erreur du passé t''a le plus appris ?'),
('sc-003', 'secrets', 'Quel est un secret pas très glorieux que tu peux confier sans risque ?'),
('sc-004', 'secrets', 'De quoi as-tu le plus peur en ce moment ?'),
('sc-005', 'secrets', 'Qu''est-ce que tu n''as jamais dit à personne et que tu aimerais déposer ici ?'),
('sc-006', 'secrets', 'Quelle période de ta vie a été la plus difficile, et qu''en as-tu gardé ?'),
('sc-007', 'secrets', 'Qu''est-ce qui te rend vulnérable et que tu caches souvent ?'),
('sc-008', 'secrets', 'Quelle confidence changerait quelque chose entre nous, selon toi ?'),

-- Pimenté
('pi-001', 'pimente', 'Qu''est-ce qui t''attire physiquement chez moi ?'),
('pi-002', 'pimente', 'Quel compliment un peu osé aimerais-tu me faire maintenant ?'),
('pi-003', 'pimente', 'Qu''est-ce qui crée la tension, pour toi, entre deux personnes ?'),
('pi-004', 'pimente', 'Où aimerais-tu qu''on se retrouve, juste nous deux, sans contrainte ?'),
('pi-005', 'pimente', 'Quel geste tendre et audacieux te ferait sourire instantanément ?'),
('pi-006', 'pimente', 'Qu''est-ce que tu trouves irrésistible quand je le fais ?'),
('pi-007', 'pimente', 'Quel moment à deux voudrais-tu prolonger sans fin ?'),
('pi-008', 'pimente', 'Qu''est-ce qui te plaît dans le fait d''être désiré(e) ?'),

-- Très intime — 18+ (rédaction respectueuse, consentement requis)
('ti-001', 'tres_intime', 'Comment aimes-tu que l''on te parle dans un moment d''intimité ?'),
('ti-002', 'tres_intime', 'Qu''est-ce qui te fait te sentir respecté(e) et en confiance lors d''un moment intime ?'),
('ti-003', 'tres_intime', 'Comment exprimes-tu, ou vérifies-tu, que l''autre est d''accord ?'),
('ti-004', 'tres_intime', 'Quelles attentions font que tu te sens vraiment désiré(e) ?'),
('ti-005', 'tres_intime', 'Y a-t-il une limite que tu aimerais que l''on clarifie entre nous ?'),
('ti-006', 'tres_intime', 'Qu''est-ce qui, selon toi, rend un moment intime vraiment réussi ?'),
('ti-007', 'tres_intime', 'Comment aimes-tu prendre soin de l''autre après un moment intime ?'),
('ti-008', 'tres_intime', 'Qu''aimerais-tu que l''on explore, uniquement si nous sommes tous les deux d''accord ?'),

-- Avenir et relations
('av-001', 'avenir', 'Qu''aimerais-tu que notre relation soit devenue dans un an ?'),
('av-002', 'avenir', 'Quelles sont tes limites non négociables dans une relation ?'),
('av-003', 'avenir', 'Comment vois-tu une relation saine au quotidien ?'),
('av-004', 'avenir', 'Qu''aimerais-tu qu''on décide ensemble, et pas chacun de son côté ?'),
('av-005', 'avenir', 'Qu''est-ce qui te ferait dire que notre duo a réussi ?'),
('av-006', 'avenir', 'Quel projet aimerais-tu qu''on envisage sérieusement ?'),
('av-007', 'avenir', 'Comment gères-tu les désaccords, et que souhaites-tu de moi dans ces moments ?'),
('av-008', 'avenir', 'Quelle promesse simple pourrais-tu me faire et tenir ?')

on conflict (code) do nothing;
