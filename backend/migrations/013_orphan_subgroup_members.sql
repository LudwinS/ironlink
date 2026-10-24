-- Auditoría: quien salió, fue expulsado o baneado de un nodo seguía en sus
-- subgrupos y recuperaba los privados al volver. El backend ya los limpia;
-- esto elimina las pertenencias huérfanas que quedaron de antes.
DELETE FROM subgrupo_miembros sm
USING subgrupos s
WHERE sm.subgrupo_id = s.id
  AND NOT EXISTS (
      SELECT 1 FROM nodo_miembros nm
      WHERE nm.nodo_id = s.nodo_id AND nm.user_id = sm.user_id
  );
